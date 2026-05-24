package controlserver

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"path/filepath"

	controlv1 "celltunnel/daemon/internal/controlv1"

	"google.golang.org/grpc"
)

// Serve starts the typed gRPC control service on the configured Unix domain socket.
func Serve(ctx context.Context, socketPath string, service *Service) error {
	logger := slog.Default().With("component", "controlserver", "socket_path", socketPath)
	logger.InfoContext(ctx, "starting typed control server")

	if err := os.MkdirAll(filepath.Dir(socketPath), 0o755); err != nil {
		return fmt.Errorf("create control socket directory: %w", err)
	}
	if err := os.RemoveAll(socketPath); err != nil {
		return fmt.Errorf("remove stale control socket: %w", err)
	}

	listenConfig := net.ListenConfig{}
	listener, err := listenConfig.Listen(ctx, "unix", socketPath)
	if err != nil {
		return fmt.Errorf("listen on control socket: %w", err)
	}
	if err := os.Chmod(socketPath, 0o666); err != nil {
		closeErr := listener.Close()
		if closeErr != nil {
			logger.ErrorContext(ctx, "control listener close after chmod failure failed", "err", closeErr)
		}
		return fmt.Errorf("set control socket permissions: %w", err)
	}
	listener = newLoggingListener(listener, logger)
	defer func() {
		if closeErr := listener.Close(); closeErr != nil {
			if !errors.Is(closeErr, net.ErrClosed) {
				logger.ErrorContext(ctx, "control listener close failed", "err", closeErr)
			}
		}
		if removeErr := os.RemoveAll(socketPath); removeErr != nil {
			logger.ErrorContext(ctx, "control socket cleanup failed", "err", removeErr)
		}
	}()

	server := grpc.NewServer(
		grpc.StatsHandler(newGRPCStatsHandler(logger)),
	)
	controlv1.RegisterTunnelControlServiceServer(server, service)

	go func() {
		defer func() {
			if recovered := recover(); recovered != nil {
				panicError := fmt.Errorf("shutdown goroutine panic: %v", recovered)
				logger.ErrorContext(ctx, "control server shutdown goroutine panicked", "err", panicError)
			}
		}()
		<-ctx.Done()
		logger.InfoContext(ctx, "control server shutdown requested")
		if closeErr := listener.Close(); closeErr != nil {
			if !errors.Is(closeErr, net.ErrClosed) {
				logger.ErrorContext(ctx, "control listener close during shutdown failed", "err", closeErr)
			}
		}
		server.Stop()
		if shutdownErr := service.Shutdown(); shutdownErr != nil {
			logger.ErrorContext(ctx, "service shutdown failed", "err", shutdownErr)
		}
	}()

	if err := server.Serve(listener); err != nil && ctx.Err() == nil && !errors.Is(err, grpc.ErrServerStopped) && !errors.Is(err, net.ErrClosed) {
		return fmt.Errorf("serve gRPC control server: %w", err)
	}
	logger.InfoContext(ctx, "control server stopped")
	return nil
}

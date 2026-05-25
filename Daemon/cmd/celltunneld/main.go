// Package main runs the Cell Tunnel daemon gRPC control service.
package main

import (
	"celltunnel/daemon/internal/controlserver"
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"
)

const (
	defaultControlSocketPath = "/var/run/io.goodkind.celltunnel/control.sock"
	controlSocketEnvironment = "CELL_TUNNEL_CONTROL_SOCKET"
	logLevelEnvironment      = "CELL_TUNNEL_LOG_LEVEL"
	defaultLogLevel          = slog.LevelDebug
)

func main() {
	configureLogging()
	slog.Info("celltunneld process started")
	if err := run(os.Args[1:]); err != nil {
		slog.Error("celltunneld process failed", "err", err)
		os.Exit(1)
	}
	slog.Info("celltunneld process completed")
}

func configureLogging() {
	handler := slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{
		Level: configuredLogLevel(),
	})
	slog.SetDefault(slog.New(handler).With("service", "celltunneld"))
}

var logLevelByName = map[string]slog.Level{
	"debug":   slog.LevelDebug,
	"info":    slog.LevelInfo,
	"warn":    slog.LevelWarn,
	"warning": slog.LevelWarn,
	"error":   slog.LevelError,
}

func configuredLogLevel() slog.Level {
	raw := strings.TrimSpace(os.Getenv(logLevelEnvironment))
	if raw == "" {
		return defaultLogLevel
	}
	if level, ok := logLevelByName[strings.ToLower(raw)]; ok {
		return level
	}
	fmt.Fprintf(os.Stderr, "unknown %s value %q; using debug\n", logLevelEnvironment, raw)
	return defaultLogLevel
}

func run(arguments []string) error {
	if len(arguments) > 1 {
		printUsage()
		return fmt.Errorf("unknown arguments: %v", arguments)
	}
	if len(arguments) == 1 && arguments[0] != "serve" {
		printUsage()
		return fmt.Errorf("unknown command: %s", arguments[0])
	}

	processContext, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := controlserver.Serve(processContext, controlSocketPath(), controlserver.NewDefaultService()); err != nil {
		slog.ErrorContext(processContext, "celltunneld control server failed", "err", err)
		return fmt.Errorf("serve control server: %w", err)
	}
	return nil
}

func controlSocketPath() string {
	if configuredPath := os.Getenv(controlSocketEnvironment); configuredPath != "" {
		return configuredPath
	}
	return defaultControlSocketPath
}

func printUsage() {
	fmt.Fprintf(os.Stderr, "usage: celltunneld [serve]\n")
}

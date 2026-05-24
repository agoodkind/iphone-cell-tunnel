package controlserver

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"sync/atomic"

	"google.golang.org/grpc/stats"
	grpcstatus "google.golang.org/grpc/status"
)

type contextKey string

const (
	connIDContextKey    contextKey = "controlserver-conn-id"
	rpcMethodContextKey contextKey = "controlserver-rpc-method"
)

type loggingListener struct {
	net.Listener
	logger *slog.Logger
}

type grpcStatsHandler struct {
	logger     *slog.Logger
	nextConnID atomic.Uint64
}

func newLoggingListener(listener net.Listener, logger *slog.Logger) net.Listener {
	return &loggingListener{
		Listener: listener,
		logger:   logger,
	}
}

func (listener *loggingListener) Accept() (net.Conn, error) {
	connection, err := listener.Listener.Accept()
	if err != nil {
		listener.logger.Error("control listener accept failed", "err", err)
		return nil, fmt.Errorf("accept control connection: %w", err)
	}

	listener.logger.Info(
		"control listener accepted connection",
		"local_addr",
		formatAddress(connection.LocalAddr()),
		"remote_addr",
		formatAddress(connection.RemoteAddr()),
	)
	return connection, nil
}

func newGRPCStatsHandler(logger *slog.Logger) stats.Handler {
	return &grpcStatsHandler{logger: logger}
}

func (handler *grpcStatsHandler) TagRPC(contextValue context.Context, info *stats.RPCTagInfo) context.Context {
	return context.WithValue(contextValue, rpcMethodContextKey, info.FullMethodName)
}

func (handler *grpcStatsHandler) HandleRPC(contextValue context.Context, rpcStats stats.RPCStats) {
	methodName, _ := contextValue.Value(rpcMethodContextKey).(string)
	connectionID, _ := contextValue.Value(connIDContextKey).(uint64)

	switch typedStats := rpcStats.(type) {
	case *stats.Begin:
		handler.logger.InfoContext(
			contextValue,
			"grpc rpc begin",
			"conn_id",
			connectionID,
			"method",
			methodName,
			"is_client_stream",
			typedStats.IsClientStream,
			"is_server_stream",
			typedStats.IsServerStream,
		)
	case *stats.End:
		handler.logger.InfoContext(
			contextValue,
			"grpc rpc end",
			"conn_id",
			connectionID,
			"method",
			methodName,
			"status_code",
			rpcStatusCode(typedStats.Error),
			"err",
			typedStats.Error,
		)
	}
}

func (handler *grpcStatsHandler) TagConn(contextValue context.Context, info *stats.ConnTagInfo) context.Context {
	connectionID := handler.nextConnID.Add(1)
	handler.logger.InfoContext(
		contextValue,
		"grpc transport connection tagged",
		"conn_id",
		connectionID,
		"local_addr",
		formatAddress(info.LocalAddr),
		"remote_addr",
		formatAddress(info.RemoteAddr),
	)
	return context.WithValue(contextValue, connIDContextKey, connectionID)
}

func (handler *grpcStatsHandler) HandleConn(contextValue context.Context, connectionStats stats.ConnStats) {
	connectionID, _ := contextValue.Value(connIDContextKey).(uint64)

	switch connectionStats.(type) {
	case *stats.ConnBegin:
		handler.logger.InfoContext(contextValue, "grpc transport connection open", "conn_id", connectionID)
	case *stats.ConnEnd:
		handler.logger.InfoContext(contextValue, "grpc transport connection close", "conn_id", connectionID)
	}
}

func formatAddress(address net.Addr) string {
	if address == nil {
		return ""
	}
	return address.String()
}

func rpcStatusCode(err error) string {
	if err == nil {
		return "OK"
	}
	return grpcstatus.Code(err).String()
}

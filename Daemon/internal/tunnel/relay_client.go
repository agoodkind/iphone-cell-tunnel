package tunnel

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"strings"
	"sync"
	"time"

	"golang.zx2c4.com/wireguard/conn"
)

const (
	relayDialTimeout = 10 * time.Second
	relayReadSize    = 64 * 1024
	relayHelloStream = 1
)

// TCPRelayClient connects the daemon's WireGuard bind to the foreground iPhone relay.
type TCPRelayClient struct {
	localEndpoint     string
	serverEndpoint    RelayEndpoint
	bind              *RelayDatagramBind
	logger            *slog.Logger
	connection        net.Conn
	peerEndpoint      conn.Endpoint
	writeMutex        sync.Mutex
	eventMutex        sync.Mutex
	closeOnce         sync.Once
	disconnectOnce    sync.Once
	cancel            context.CancelFunc
	disconnectHandler func(error)
}

var (
	errRelayClientClosed       = errors.New("relay client is closed")
	errRelayConnectionClosed   = errors.New("relay connection closed")
	errRelayProtocolFrameError = errors.New("relay protocol frame error")
)

// NewTCPRelayClient creates a relay client for one iPhone relay TCP endpoint.
func NewTCPRelayClient(
	localEndpoint string,
	serverEndpoint RelayEndpoint,
	bind *RelayDatagramBind,
) (*TCPRelayClient, error) {
	peerEndpoint, err := bind.ParseEndpoint(serverEndpoint.AddressPort())
	if err != nil {
		return nil, err
	}
	return &TCPRelayClient{
		localEndpoint:  localEndpoint,
		serverEndpoint: serverEndpoint,
		bind:           bind,
		logger:         slog.Default().With("component", "relay-client"),
		peerEndpoint:   peerEndpoint,
	}, nil
}

// SetDisconnectHandler registers the callback used by the runtime to stop after unexpected relay loss.
func (client *TCPRelayClient) SetDisconnectHandler(handler func(error)) {
	client.eventMutex.Lock()
	defer client.eventMutex.Unlock()
	client.disconnectHandler = handler
	client.logger.Info("relay client disconnect handler configured", "configured", handler != nil)
}

// Start opens the local relay connection, sends the typed hello payload, and starts reading frames.
func (client *TCPRelayClient) Start(parentContext context.Context) error {
	logger := client.logger.With("local_endpoint_configured", client.localEndpoint != "")
	logger.InfoContext(parentContext, "relay client starting")
	dialContext, cancelDial := context.WithTimeout(parentContext, relayDialTimeout)
	defer cancelDial()

	dialer := net.Dialer{}
	connection, err := dialer.DialContext(dialContext, "tcp", client.localEndpoint)
	if err != nil {
		logger.ErrorContext(parentContext, "relay client dial failed", "err", err)
		return fmt.Errorf("dial relay client: %w", err)
	}

	runContext, cancel := context.WithCancel(parentContext)
	client.cancel = cancel
	client.connection = connection
	if err := client.sendHello(); err != nil {
		logger.ErrorContext(parentContext, "relay client hello failed", "err", err)
		if closeErr := connection.Close(); closeErr != nil {
			logger.ErrorContext(parentContext, "relay client close after hello failure failed", "err", closeErr)
		}
		cancel()
		return err
	}

	go func() {
		defer func() {
			recoveredValue := recover()
			if recoveredValue == nil {
				return
			}
			logger.ErrorContext(
				runContext,
				"relay client read loop recovered failure",
				"err",
				fmt.Errorf("relay read loop failure: %v", recoveredValue),
			)
			client.notifyUnexpectedDisconnect(fmt.Errorf("relay read loop recovered failure: %v", recoveredValue))
		}()
		client.readLoop(runContext)
	}()
	logger.InfoContext(parentContext, "relay client started")
	return nil
}

// SendWireGuardDatagram sends one encrypted WireGuard UDP datagram to the iPhone relay.
func (client *TCPRelayClient) SendWireGuardDatagram(datagram []byte) error {
	frame := RelayFrame{
		Version:       relayFrameVersion,
		StreamID:      0,
		Operation:     RelayOperationWireGuardDatagram,
		AddressFamily: client.serverEndpoint.AddressFamily,
		Payload:       datagram,
	}
	client.logger.Debug("relay client sending wireguard datagram", "bytes", len(datagram))
	return client.writeFrame(frame)
}

// Close closes the local relay connection.
func (client *TCPRelayClient) Close() error {
	var closeErr error
	client.closeOnce.Do(func() {
		client.logger.Info("relay client closing")
		if client.cancel != nil {
			client.cancel()
		}
		if client.connection != nil {
			closeErr = client.connection.Close()
		}
		if closeErr != nil {
			client.logger.Error("relay client close failed", "err", closeErr)
			closeErr = fmt.Errorf("close relay client: %w", closeErr)
		}
	})
	return closeErr
}

func (client *TCPRelayClient) sendHello() error {
	payload, err := MarshalRelayHandshake(client.serverEndpoint)
	if err != nil {
		return err
	}
	frame := RelayFrame{
		Version:       relayFrameVersion,
		StreamID:      relayHelloStream,
		Operation:     RelayOperationHello,
		AddressFamily: client.serverEndpoint.AddressFamily,
		Payload:       payload,
	}
	client.logger.Info("relay client sending hello", "endpoint_family", client.serverEndpoint.AddressFamily)
	return client.writeFrame(frame)
}

func (client *TCPRelayClient) writeFrame(frame RelayFrame) error {
	client.writeMutex.Lock()
	defer client.writeMutex.Unlock()

	if client.connection == nil {
		client.logger.Error("relay client write failed", "err", errRelayClientClosed)
		return errRelayClientClosed
	}
	encodedFrame, err := MarshalRelayFrame(frame)
	if err != nil {
		client.logger.Error("relay client frame encode failed", "err", err)
		return err
	}
	totalWritten := 0
	for totalWritten < len(encodedFrame) {
		written, err := client.connection.Write(encodedFrame[totalWritten:])
		if err != nil {
			client.logger.Error("relay client write failed", "err", err)
			return fmt.Errorf("write relay frame: %w", err)
		}
		totalWritten += written
	}
	client.logger.Debug("relay client frame written", "operation", frame.Operation, "bytes", len(encodedFrame))
	return nil
}

func (client *TCPRelayClient) readLoop(runContext context.Context) {
	logger := client.logger.With("boundary", "relay-read-loop")
	logger.InfoContext(runContext, "relay client read loop started")
	defer logger.InfoContext(runContext, "relay client read loop stopped")

	buffer := RelayFrameBuffer{}
	readBuffer := make([]byte, relayReadSize)
	for {
		select {
		case <-runContext.Done():
			logger.DebugContext(runContext, "relay client read loop cancelled")
			return
		default:
		}

		count, err := client.connection.Read(readBuffer)
		if err != nil {
			if runContext.Err() != nil {
				logger.DebugContext(runContext, "relay client read loop cancelled")
				return
			}
			if errors.Is(err, io.EOF) || errors.Is(err, net.ErrClosed) {
				logger.ErrorContext(runContext, "relay client read loop connection closed unexpectedly", "err", err)
				client.notifyUnexpectedDisconnect(fmt.Errorf("%w: %w", errRelayConnectionClosed, err))
				return
			}
			logger.ErrorContext(runContext, "relay client read failed", "err", err)
			client.notifyUnexpectedDisconnect(fmt.Errorf("read relay frame: %w", err))
			return
		}
		if count == 0 {
			continue
		}

		frames, err := buffer.ReadFrames(readBuffer[:count])
		if err != nil {
			logger.ErrorContext(runContext, "relay client frame decode failed", "err", err)
			client.notifyUnexpectedDisconnect(fmt.Errorf("%w: %w", errRelayProtocolFrameError, err))
			return
		}
		for _, frame := range frames {
			client.handleFrame(frame)
		}
	}
}

func (client *TCPRelayClient) notifyUnexpectedDisconnect(err error) {
	client.disconnectOnce.Do(func() {
		client.eventMutex.Lock()
		handler := client.disconnectHandler
		client.eventMutex.Unlock()

		if handler == nil {
			client.logger.Error("relay client disconnect handler missing", "err", err)
			return
		}
		client.logger.Error("relay client notifying disconnect", "err", err)
		handler(err)
	})
}

func (client *TCPRelayClient) handleFrame(frame RelayFrame) {
	logger := client.logger.With("operation", frame.Operation, "stream_id", frame.StreamID)
	switch frame.Operation {
	case RelayOperationHello, RelayOperationPairConfirm, RelayOperationStats:
		logger.Info("relay client ignored control frame", "bytes", len(frame.Payload))
	case RelayOperationWireGuardDatagram:
		logger.Debug("relay client received wireguard datagram", "bytes", len(frame.Payload))
		if err := client.bind.InjectInboundDatagram(frame.Payload, client.peerEndpoint); err != nil {
			logger.Error("relay client inbound datagram inject failed", "err", err)
		}
	case RelayOperationPathStatus:
		logger.Info("relay client received path status", "bytes", len(frame.Payload))
	case RelayOperationError:
		message := strings.TrimSpace(string(frame.Payload))
		if message == "" {
			message = fmt.Sprintf("relay error payload bytes=%d", len(frame.Payload))
		}
		err := fmt.Errorf("relay error: %s", message)
		logger.Error("relay client received relay error", "err", err)
		client.notifyUnexpectedDisconnect(err)
	default:
		logger.Info("relay client ignored frame", "bytes", len(frame.Payload))
	}
}

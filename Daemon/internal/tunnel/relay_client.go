package tunnel

import (
	"celltunnel/daemon/internal/usbmuxd"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.zx2c4.com/wireguard/conn"
)

const usbmuxdRelayPrefix = "usbmuxd:"

const (
	relayDialTimeout       = 10 * time.Second
	relayReadSize          = 64 * 1024
	relayHelloStream       = 1
	relayKeepAliveIdle     = 10 * time.Second
	relayHeartbeatInterval = 8 * time.Second
)

// RelayDialer opens the local relay channel used to reach the foreground iPhone app.
type RelayDialer func(context.Context) (net.Conn, error)

// TCPRelayClient connects the daemon's WireGuard bind to the foreground iPhone relay.
type TCPRelayClient struct {
	localEndpoint     string
	serverEndpoint    RelayEndpoint
	bind              *RelayDatagramBind
	logger            *slog.Logger
	dial              RelayDialer
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

// NewTCPRelayClient creates a relay client that dials the iPhone relay over plain TCP.
func NewTCPRelayClient(
	localEndpoint string,
	serverEndpoint RelayEndpoint,
	bind *RelayDatagramBind,
) (*TCPRelayClient, error) {
	dial := func(dialContext context.Context) (net.Conn, error) {
		dialer := net.Dialer{}
		return dialer.DialContext(dialContext, "tcp", localEndpoint)
	}
	return NewRelayClientWithDialer(localEndpoint, serverEndpoint, bind, dial)
}

// NewRelayClientWithDialer creates a relay client that uses the supplied dialer to open the local channel.
func NewRelayClientWithDialer(
	localEndpoint string,
	serverEndpoint RelayEndpoint,
	bind *RelayDatagramBind,
	dial RelayDialer,
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
		dial:           dial,
		peerEndpoint:   peerEndpoint,
	}, nil
}

// buildRelayClient picks the right transport based on the local endpoint string.
// An endpoint of the form "usbmuxd:<udid>:<port>" dials through usbmuxd; anything
// else is treated as a plain TCP "host:port" address.
func buildRelayClient(
	localEndpoint string,
	serverEndpoint RelayEndpoint,
	bind *RelayDatagramBind,
) (*TCPRelayClient, error) {
	if strings.HasPrefix(localEndpoint, usbmuxdRelayPrefix) {
		udid, port, err := parseUsbmuxdRelayEndpoint(localEndpoint)
		if err != nil {
			return nil, err
		}
		dial := newUsbmuxdDialer(udid, port)
		return NewRelayClientWithDialer(localEndpoint, serverEndpoint, bind, dial)
	}
	return NewTCPRelayClient(localEndpoint, serverEndpoint, bind)
}

func parseUsbmuxdRelayEndpoint(localEndpoint string) (string, uint16, error) {
	body := strings.TrimPrefix(localEndpoint, usbmuxdRelayPrefix)
	separatorIndex := strings.LastIndex(body, ":")
	if separatorIndex <= 0 || separatorIndex == len(body)-1 {
		err := fmt.Errorf("usbmuxd relay endpoint malformed: %q", localEndpoint)
		slog.Error("usbmuxd relay endpoint parse failed", "err", err, "endpoint", localEndpoint)
		return "", 0, err
	}
	udid := body[:separatorIndex]
	portText := body[separatorIndex+1:]
	parsedPort, err := strconv.ParseUint(portText, 10, 16)
	if err != nil {
		slog.Error("usbmuxd relay endpoint port parse failed", "err", err, "port", portText)
		return "", 0, fmt.Errorf("usbmuxd relay endpoint port %q: %w", portText, err)
	}
	return udid, uint16(parsedPort), nil
}

func newUsbmuxdDialer(udid string, port uint16) RelayDialer {
	dialerLogger := slog.Default().With("component", "relay-client", "transport", "usbmuxd", "udid", udid, "port", port)
	return func(dialContext context.Context) (net.Conn, error) {
		devices, err := usbmuxd.ListDevices()
		if err != nil {
			dialerLogger.Error("usbmuxd dialer list devices failed", "err", err)
			return nil, fmt.Errorf("usbmuxd list devices: %w", err)
		}
		deviceID, ok := selectUsbmuxdDeviceID(devices, udid)
		if !ok {
			err := fmt.Errorf("usbmuxd device with udid %q not attached", udid)
			dialerLogger.Error("usbmuxd dialer device not attached", "err", err)
			return nil, err
		}
		dialDone := make(chan dialResult, 1)
		go func() {
			defer func() {
				recovered := recover()
				if recovered == nil {
					return
				}
				dialerLogger.Error("usbmuxd dialer goroutine recovered failure", "err", fmt.Errorf("usbmuxd dial recovered: %v", recovered))
				dialDone <- dialResult{err: fmt.Errorf("usbmuxd dial recovered: %v", recovered)}
			}()
			connection, err := usbmuxd.Dial(deviceID, port)
			dialDone <- dialResult{connection: connection, err: err}
		}()
		select {
		case <-dialContext.Done():
			return nil, dialContext.Err()
		case result := <-dialDone:
			return result.connection, result.err
		}
	}
}

type dialResult struct {
	connection net.Conn
	err        error
}

func selectUsbmuxdDeviceID(devices []usbmuxd.Device, udid string) (int, bool) {
	for _, device := range devices {
		if device.UDID == udid {
			return device.DeviceID, true
		}
	}
	return 0, false
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

	connection, err := client.dial(dialContext)
	if err != nil {
		logger.ErrorContext(parentContext, "relay client dial failed", "err", err)
		return fmt.Errorf("dial relay client: %w", err)
	}

	if tcpConnection, ok := connection.(*net.TCPConn); ok {
		if keepAliveErr := tcpConnection.SetKeepAlive(true); keepAliveErr != nil {
			logger.ErrorContext(parentContext, "relay client set keepalive failed", "err", keepAliveErr)
		}
		if keepAlivePeriodErr := tcpConnection.SetKeepAlivePeriod(relayKeepAliveIdle); keepAlivePeriodErr != nil {
			logger.ErrorContext(parentContext, "relay client set keepalive period failed", "err", keepAlivePeriodErr)
		}
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
	go func() {
		defer func() {
			recoveredValue := recover()
			if recoveredValue == nil {
				return
			}
			logger.ErrorContext(
				runContext,
				"relay client heartbeat loop recovered failure",
				"err",
				fmt.Errorf("relay heartbeat loop failure: %v", recoveredValue),
			)
			client.notifyUnexpectedDisconnect(fmt.Errorf("relay heartbeat loop recovered failure: %v", recoveredValue))
		}()
		client.heartbeatLoop(runContext)
	}()
	logger.InfoContext(parentContext, "relay client started")
	return nil
}

func (client *TCPRelayClient) heartbeatLoop(runContext context.Context) {
	ticker := time.NewTicker(relayHeartbeatInterval)
	defer ticker.Stop()
	for {
		select {
		case <-runContext.Done():
			return
		case <-ticker.C:
			if err := client.sendKeepAlive(); err != nil {
				client.logger.ErrorContext(runContext, "relay client heartbeat send failed", "err", err)
				client.notifyUnexpectedDisconnect(fmt.Errorf("send keepalive: %w", err))
				return
			}
		}
	}
}

func (client *TCPRelayClient) sendKeepAlive() error {
	frame := RelayFrame{
		Version:       relayFrameVersion,
		StreamID:      0,
		Operation:     RelayOperationKeepAlive,
		AddressFamily: client.serverEndpoint.AddressFamily,
	}
	client.logger.Info("relay client sending keepalive")
	return client.writeFrame(frame)
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
	case RelayOperationKeepAlive:
		logger.Info("relay client received keepalive")
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

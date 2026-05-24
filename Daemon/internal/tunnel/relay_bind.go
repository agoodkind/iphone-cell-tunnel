package tunnel

import (
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/netip"
	"sync"

	"golang.zx2c4.com/wireguard/conn"
)

const relayBindBatchSize = 1

// RelayDatagramSink receives encrypted WireGuard UDP datagrams emitted by wireguard-go.
type RelayDatagramSink interface {
	SendWireGuardDatagram(datagram []byte) error
}

type relayInboundDatagram struct {
	payload  []byte
	endpoint conn.Endpoint
}

// RelayDatagramBind implements wireguard-go's conn.Bind over the Mac-to-iPhone relay.
type RelayDatagramBind struct {
	logger  *slog.Logger
	inbound chan relayInboundDatagram
	sink    RelayDatagramSink
	mutex   sync.Mutex
	opened  bool
	closed  bool
}

var (
	errRelayBindAlreadyOpen  = errors.New("relay bind is already open")
	errRelayBindClosed       = errors.New("relay bind is closed")
	errRelayDatagramTooLarge = errors.New("relay datagram does not fit receive buffer")
	errRelayInboundFull      = errors.New("relay inbound queue is full")
	errRelaySinkMissing      = errors.New("relay datagram sink is not configured")
)

// NewRelayDatagramBind creates a wireguard-go bind backed by the local relay channel.
func NewRelayDatagramBind(sink RelayDatagramSink) *RelayDatagramBind {
	return &RelayDatagramBind{
		logger:  slog.Default().With("component", "relay-bind"),
		inbound: make(chan relayInboundDatagram, conn.IdealBatchSize),
		sink:    sink,
	}
}

// SetSink attaches the outbound datagram sink after relay client construction.
func (bind *RelayDatagramBind) SetSink(sink RelayDatagramSink) {
	bind.mutex.Lock()
	defer bind.mutex.Unlock()
	bind.sink = sink
	bind.logger.Info("relay bind sink configured", "configured", sink != nil)
}

// Open marks the relay bind as ready and returns its receive function.
func (bind *RelayDatagramBind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	bind.mutex.Lock()
	defer bind.mutex.Unlock()

	if bind.closed {
		bind.logger.Error("relay bind open failed", "err", errRelayBindClosed)
		return nil, 0, errRelayBindClosed
	}
	if bind.opened {
		bind.logger.Error("relay bind open failed", "err", errRelayBindAlreadyOpen)
		return nil, 0, errRelayBindAlreadyOpen
	}

	bind.opened = true
	bind.logger.Info("relay bind opened", "requested_port", port)
	return []conn.ReceiveFunc{bind.receive}, 0, nil
}

// Close closes the relay bind and unblocks pending receive calls.
func (bind *RelayDatagramBind) Close() error {
	bind.mutex.Lock()
	defer bind.mutex.Unlock()

	if bind.closed {
		bind.logger.Debug("relay bind close ignored because bind is already closed")
		return nil
	}

	bind.closed = true
	close(bind.inbound)
	bind.logger.Info("relay bind closed")
	return nil
}

// SetMark accepts wireguard-go mark requests as a no-op because no local UDP socket is opened.
func (bind *RelayDatagramBind) SetMark(mark uint32) error {
	bind.logger.Debug("relay bind mark ignored", "mark", mark)
	return nil
}

// Send forwards encrypted WireGuard datagrams to the local relay sink without rewriting bytes.
func (bind *RelayDatagramBind) Send(bufs [][]byte, endpoint conn.Endpoint) error {
	bind.mutex.Lock()
	sink := bind.sink
	closed := bind.closed
	bind.mutex.Unlock()

	if closed {
		bind.logger.Error("relay bind send failed", "err", errRelayBindClosed)
		return errRelayBindClosed
	}
	if sink == nil {
		bind.logger.Error("relay bind send failed", "err", errRelaySinkMissing)
		return errRelaySinkMissing
	}

	for _, buffer := range bufs {
		datagram := make([]byte, len(buffer))
		copy(datagram, buffer)
		endpointDescription := "unknown"
		if endpoint != nil {
			endpointDescription = endpoint.DstToString()
		}
		bind.logger.Debug("relay bind sending datagram", "bytes", len(datagram), "endpoint", endpointDescription)
		if err := sink.SendWireGuardDatagram(datagram); err != nil {
			bind.logger.Error("relay bind sink send failed", "err", err)
			return fmt.Errorf("send relay datagram to sink: %w", err)
		}
	}
	return nil
}

// ParseEndpoint converts a WireGuard endpoint string into a relay endpoint.
func (bind *RelayDatagramBind) ParseEndpoint(value string) (conn.Endpoint, error) {
	endpoint, err := ParseWireGuardEndpoint(value)
	if err != nil {
		bind.logger.Error("relay bind endpoint parse failed", "err", err)
		return nil, err
	}
	bind.logger.Info("relay bind endpoint parsed", "endpoint_family", endpoint.AddressFamily)
	return NewRelayConnEndpoint(endpoint), nil
}

// BatchSize reports the fixed relay bind batch size.
func (bind *RelayDatagramBind) BatchSize() int {
	return relayBindBatchSize
}

// InjectInboundDatagram queues an encrypted WireGuard datagram received from the iPhone relay.
func (bind *RelayDatagramBind) InjectInboundDatagram(datagram []byte, endpoint conn.Endpoint) error {
	bind.mutex.Lock()
	defer bind.mutex.Unlock()

	if bind.closed {
		bind.logger.Error("relay bind inbound inject failed", "err", errRelayBindClosed)
		return errRelayBindClosed
	}

	payload := make([]byte, len(datagram))
	copy(payload, datagram)
	select {
	case bind.inbound <- relayInboundDatagram{payload: payload, endpoint: endpoint}:
		bind.logger.Debug("relay bind inbound datagram queued", "bytes", len(payload))
		return nil
	default:
		bind.logger.Error("relay bind inbound inject failed", "err", errRelayInboundFull)
		return errRelayInboundFull
	}
}

func (bind *RelayDatagramBind) receive(
	packets [][]byte,
	sizes []int,
	endpoints []conn.Endpoint,
) (int, error) {
	datagram, ok := <-bind.inbound
	if !ok {
		bind.logger.Info("relay bind receive closed")
		return 0, net.ErrClosed
	}
	if len(packets) == 0 || len(sizes) == 0 || len(endpoints) == 0 {
		return 0, fmt.Errorf("%w: missing receive slots", errRelayDatagramTooLarge)
	}
	if len(packets[0]) < len(datagram.payload) {
		bind.logger.Error(
			"relay bind receive buffer too small",
			"err",
			errRelayDatagramTooLarge,
			"datagram_bytes",
			len(datagram.payload),
			"buffer_bytes",
			len(packets[0]),
		)
		return 0, errRelayDatagramTooLarge
	}

	copy(packets[0], datagram.payload)
	sizes[0] = len(datagram.payload)
	endpoints[0] = datagram.endpoint
	bind.logger.Debug("relay bind received datagram", "bytes", len(datagram.payload))
	return 1, nil
}

// RelayConnEndpoint adapts RelayEndpoint to wireguard-go's conn.Endpoint interface.
type RelayConnEndpoint struct {
	endpoint RelayEndpoint
	address  netip.Addr
}

// NewRelayConnEndpoint creates a conn.Endpoint for the hosted WireGuard server.
func NewRelayConnEndpoint(endpoint RelayEndpoint) *RelayConnEndpoint {
	address, err := netip.ParseAddr(endpoint.Host)
	if err != nil {
		address = netip.Addr{}
	}
	return &RelayConnEndpoint{
		endpoint: endpoint,
		address:  address,
	}
}

// ClearSrc clears sticky source state, which the relay endpoint does not track.
func (endpoint *RelayConnEndpoint) ClearSrc() {
}

// SrcToString returns an empty source because the iPhone cellular socket owns the outer source.
func (endpoint *RelayConnEndpoint) SrcToString() string {
	return ""
}

// DstToString returns the hosted WireGuard server endpoint.
func (endpoint *RelayConnEndpoint) DstToString() string {
	return endpoint.endpoint.AddressPort()
}

// DstToBytes returns stable endpoint bytes for wireguard-go cookie calculations.
func (endpoint *RelayConnEndpoint) DstToBytes() []byte {
	return []byte(endpoint.endpoint.AddressPort())
}

// DstIP returns the destination IP when the endpoint host is an IP literal.
func (endpoint *RelayConnEndpoint) DstIP() netip.Addr {
	return endpoint.address
}

// SrcIP returns an invalid address because the relay endpoint does not track local source IPs.
func (endpoint *RelayConnEndpoint) SrcIP() netip.Addr {
	return netip.Addr{}
}

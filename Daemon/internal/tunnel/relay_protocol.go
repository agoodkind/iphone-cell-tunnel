package tunnel

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"math"
)

// RelayOperation identifies the operation encoded in a local relay frame.
type RelayOperation uint8

const (
	// RelayOperationHello carries the typed startup handshake from the Mac daemon.
	RelayOperationHello RelayOperation = 1
	// RelayOperationPairConfirm is reserved for future pairing acknowledgements.
	RelayOperationPairConfirm RelayOperation = 2
	// RelayOperationKeepAlive is a no-op frame used to keep the local relay channel warm.
	RelayOperationKeepAlive RelayOperation = 10
	// RelayOperationPathStatus carries cellular path status from the iPhone app.
	RelayOperationPathStatus RelayOperation = 40
	// RelayOperationWireGuardDatagram carries one encrypted WireGuard UDP datagram.
	RelayOperationWireGuardDatagram RelayOperation = 50
	// RelayOperationError carries a relay protocol error message.
	RelayOperationError RelayOperation = 250
	// RelayOperationStats carries relay counters.
	RelayOperationStats RelayOperation = 251
)

const (
	relayFrameVersion = 1
	relayHeaderLength = 17
)

// RelayFrame is the Go representation of the shared Swift relay frame layout.
type RelayFrame struct {
	Version       uint8
	StreamID      uint64
	Operation     RelayOperation
	AddressFamily RelayAddressFamily
	Flags         uint16
	Payload       []byte
}

// RelayHandshakePayload is the JSON payload sent in the hello frame.
type RelayHandshakePayload struct {
	WireGuardServer RelayEndpoint `json:"wireGuardServer"`
}

var (
	errRelayFrameTooShort = errors.New("relay frame too short")
	errRelayVersion       = errors.New("unsupported relay frame version")
	errRelayPayloadLength = errors.New("relay frame payload length mismatch")
)

// MarshalRelayFrame serializes a relay frame while preserving payload bytes.
func MarshalRelayFrame(frame RelayFrame) ([]byte, error) {
	payloadLength, err := relayPayloadLength(frame.Payload)
	if err != nil {
		return nil, err
	}
	data := make([]byte, relayHeaderLength+len(frame.Payload))
	data[0] = relayFrameVersion
	data[1] = uint8(frame.Operation)
	data[2] = uint8(frame.AddressFamily)
	binary.BigEndian.PutUint16(data[3:5], frame.Flags)
	binary.BigEndian.PutUint64(data[5:13], frame.StreamID)
	binary.BigEndian.PutUint32(data[13:17], payloadLength)
	copy(data[relayHeaderLength:], frame.Payload)
	return data, nil
}

func relayPayloadLength(payload []byte) (uint32, error) {
	payloadLength := uint64(len(payload))
	if payloadLength > uint64(math.MaxUint32) {
		return 0, errRelayPayloadLength
	}
	return uint32(payloadLength), nil
}

// UnmarshalRelayFrame decodes one complete relay frame.
func UnmarshalRelayFrame(data []byte) (RelayFrame, error) {
	if len(data) < relayHeaderLength {
		return RelayFrame{}, errRelayFrameTooShort
	}
	if data[0] != relayFrameVersion {
		return RelayFrame{}, errRelayVersion
	}
	payloadLength := int(binary.BigEndian.Uint32(data[13:17]))
	if len(data)-relayHeaderLength != payloadLength {
		return RelayFrame{}, errRelayPayloadLength
	}

	payload := make([]byte, payloadLength)
	copy(payload, data[relayHeaderLength:])
	return RelayFrame{
		Version:       data[0],
		Operation:     RelayOperation(data[1]),
		AddressFamily: RelayAddressFamily(data[2]),
		Flags:         binary.BigEndian.Uint16(data[3:5]),
		StreamID:      binary.BigEndian.Uint64(data[5:13]),
		Payload:       payload,
	}, nil
}

// RelayFrameBuffer accumulates partial TCP reads into complete relay frames.
type RelayFrameBuffer struct {
	storage []byte
}

// ReadFrames adds bytes and returns every complete frame now available.
func (buffer *RelayFrameBuffer) ReadFrames(data []byte) ([]RelayFrame, error) {
	buffer.storage = append(buffer.storage, data...)
	return buffer.drainFrames()
}

func (buffer *RelayFrameBuffer) drainFrames() ([]RelayFrame, error) {
	frames := make([]RelayFrame, 0)
	for len(buffer.storage) >= relayHeaderLength {
		if buffer.storage[0] != relayFrameVersion {
			return nil, errRelayVersion
		}
		payloadLength := int(binary.BigEndian.Uint32(buffer.storage[13:17]))
		frameLength := relayHeaderLength + payloadLength
		if len(buffer.storage) < frameLength {
			break
		}

		frame, err := UnmarshalRelayFrame(buffer.storage[:frameLength])
		if err != nil {
			return nil, err
		}
		frames = append(frames, frame)
		buffer.storage = buffer.storage[frameLength:]
	}
	return frames, nil
}

// MarshalRelayHandshake serializes the hosted WireGuard server endpoint for the iPhone app.
func MarshalRelayHandshake(endpoint RelayEndpoint) ([]byte, error) {
	payload := RelayHandshakePayload{WireGuardServer: endpoint}
	data, err := json.Marshal(payload)
	if err != nil {
		logger.Error("relay handshake marshal failed", "err", err)
		return nil, fmt.Errorf("marshal relay handshake: %w", err)
	}
	return data, nil
}

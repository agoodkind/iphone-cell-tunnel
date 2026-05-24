package tunnel

import "testing"

func TestRelayFramePreservesWireGuardDatagramBytes(t *testing.T) {
	payload := []byte{0x00, 0x01, 0xfe, 0xff, 0x45, 0x00}
	frame := RelayFrame{
		Version:       relayFrameVersion,
		StreamID:      99,
		Operation:     RelayOperationWireGuardDatagram,
		AddressFamily: RelayAddressFamilyIPv4,
		Flags:         7,
		Payload:       payload,
	}

	encodedFrame, err := MarshalRelayFrame(frame)
	if err != nil {
		t.Fatalf("marshal relay frame: %v", err)
	}
	decodedFrame, err := UnmarshalRelayFrame(encodedFrame)
	if err != nil {
		t.Fatalf("decode relay frame: %v", err)
	}

	if decodedFrame.Operation != RelayOperationWireGuardDatagram {
		t.Fatalf("unexpected operation: %d", decodedFrame.Operation)
	}
	if string(decodedFrame.Payload) != string(payload) {
		t.Fatalf("payload changed: %#v", decodedFrame.Payload)
	}
}

func TestRelayHandshakeEncodesWireGuardEndpoint(t *testing.T) {
	endpoint := RelayEndpoint{
		AddressFamily: RelayAddressFamilyIPv4,
		Host:          "203.0.113.10",
		Port:          51820,
	}

	payload, err := MarshalRelayHandshake(endpoint)
	if err != nil {
		t.Fatalf("encode relay handshake: %v", err)
	}

	expected := `{"wireGuardServer":{"addressFamily":4,"host":"203.0.113.10","port":51820}}`
	if string(payload) != expected {
		t.Fatalf("unexpected payload: %s", string(payload))
	}
}

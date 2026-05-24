package tunnel

import (
	"bytes"
	"testing"

	"golang.zx2c4.com/wireguard/conn"
)

type recordingRelaySink struct {
	datagrams [][]byte
}

func (sink *recordingRelaySink) SendWireGuardDatagram(datagram []byte) error {
	copiedDatagram := make([]byte, len(datagram))
	copy(copiedDatagram, datagram)
	sink.datagrams = append(sink.datagrams, copiedDatagram)
	return nil
}

func TestRelayDatagramBindPreservesOutgoingDatagramBytes(t *testing.T) {
	sink := &recordingRelaySink{}
	bind := NewRelayDatagramBind(sink)
	endpoint := NewRelayConnEndpoint(RelayEndpoint{
		AddressFamily: RelayAddressFamilyIPv4,
		Host:          "203.0.113.10",
		Port:          51820,
	})
	datagram := []byte{0x01, 0x02, 0x03, 0x04}

	if err := bind.Send([][]byte{datagram}, endpoint); err != nil {
		t.Fatalf("send datagram: %v", err)
	}
	datagram[0] = 0xff

	if len(sink.datagrams) != 1 {
		t.Fatalf("unexpected datagram count: %d", len(sink.datagrams))
	}
	if !bytes.Equal(sink.datagrams[0], []byte{0x01, 0x02, 0x03, 0x04}) {
		t.Fatalf("datagram changed: %#v", sink.datagrams[0])
	}
}

func TestRelayDatagramBindDeliversInboundDatagramBytes(t *testing.T) {
	bind := NewRelayDatagramBind(nil)
	receiveFunctions, _, err := bind.Open(0)
	if err != nil {
		t.Fatalf("open relay bind: %v", err)
	}
	endpoint := NewRelayConnEndpoint(RelayEndpoint{
		AddressFamily: RelayAddressFamilyIPv6,
		Host:          "2001:db8::10",
		Port:          51820,
	})
	datagram := []byte{0x04, 0x03, 0x02, 0x01}

	if err := bind.InjectInboundDatagram(datagram, endpoint); err != nil {
		t.Fatalf("inject datagram: %v", err)
	}
	datagram[0] = 0xff

	packets := [][]byte{make([]byte, 64)}
	sizes := make([]int, 1)
	endpoints := make([]conn.Endpoint, 1)
	count, err := receiveFunctions[0](packets, sizes, endpoints)
	if err != nil {
		t.Fatalf("receive datagram: %v", err)
	}

	if count != 1 {
		t.Fatalf("unexpected receive count: %d", count)
	}
	if sizes[0] != 4 {
		t.Fatalf("unexpected datagram size: %d", sizes[0])
	}
	if !bytes.Equal(packets[0][:sizes[0]], []byte{0x04, 0x03, 0x02, 0x01}) {
		t.Fatalf("datagram changed: %#v", packets[0][:sizes[0]])
	}
	if endpoints[0].DstToString() != "[2001:db8::10]:51820" {
		t.Fatalf("unexpected endpoint: %s", endpoints[0].DstToString())
	}
}

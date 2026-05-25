package tunnel

import (
	"strings"
	"testing"
)

const testWireGuardConfig = `
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= # gitleaks:allow
Address = 198.18.0.2/15, fd7a:ce11:7a11::2/64
ListenPort = 51821

[Peer]
PublicKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=
PresharedKey = AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=
Endpoint = [2001:db8::10]:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
`

func TestParseWireGuardConfig(t *testing.T) {
	config, err := ParseWireGuardConfig(strings.NewReader(testWireGuardConfig))
	if err != nil {
		t.Fatalf("parse wireguard config: %v", err)
	}

	if len(config.Interface.Addresses) != 2 {
		t.Fatalf("unexpected interface addresses: %#v", config.Interface.Addresses)
	}
	if config.Peer.Endpoint.AddressFamily != RelayAddressFamilyIPv6 {
		t.Fatalf("unexpected endpoint family: %#v", config.Peer.Endpoint)
	}
	if config.Peer.Endpoint.Host != "2001:db8::10" {
		t.Fatalf("unexpected endpoint host: %#v", config.Peer.Endpoint)
	}
	if config.Peer.Endpoint.Port != 51820 {
		t.Fatalf("unexpected endpoint port: %#v", config.Peer.Endpoint)
	}
	if len(config.Peer.AllowedIPs) != 2 {
		t.Fatalf("unexpected allowed IPs: %#v", config.Peer.AllowedIPs)
	}
	if !config.Peer.HasPresharedKey {
		t.Fatal("expected preshared key to be parsed")
	}
	if config.Peer.PersistentKeepaliveSeconds != 25 {
		t.Fatalf("unexpected keepalive: %d", config.Peer.PersistentKeepaliveSeconds)
	}
}

func TestWireGuardConfigRendersUAPIConfig(t *testing.T) {
	config, err := ParseWireGuardConfig(strings.NewReader(testWireGuardConfig))
	if err != nil {
		t.Fatalf("parse wireguard config: %v", err)
	}

	uapiConfig := config.UAPIConfig()
	expectedFragments := []string{
		"private_key=0000000000000000000000000000000000000000000000000000000000000000", // gitleaks:allow
		"listen_port=51821",
		"replace_peers=true",
		"public_key=0101010101010101010101010101010101010101010101010101010101010101",
		"preshared_key=0202020202020202020202020202020202020202020202020202020202020202",
		"endpoint=[2001:db8::10]:51820",
		"allowed_ip=0.0.0.0/0",
		"allowed_ip=::/0",
		"persistent_keepalive_interval=25",
	}

	for _, expectedFragment := range expectedFragments {
		if !strings.Contains(uapiConfig, expectedFragment) {
			t.Fatalf("UAPI config missing %q:\n%s", expectedFragment, uapiConfig)
		}
	}
}

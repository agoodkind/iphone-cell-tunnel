package tunnel

import (
	"strings"
	"testing"
)

func TestDefaultConfigDoesNotReadStartEnvironment(t *testing.T) {
	config := DefaultConfig()

	if config.WireGuardConfigPath != "" {
		t.Fatalf("default config set wireguard path: %q", config.WireGuardConfigPath)
	}
	if config.LocalRelayEndpoint != "" {
		t.Fatalf("default config set relay endpoint: %q", config.LocalRelayEndpoint)
	}
}

func TestStartOptionsValidateRequiredValues(t *testing.T) {
	if err := (StartOptions{}).Validate(); err != ErrWireGuardConfigPathMissing {
		t.Fatalf("missing config path returned wrong error: %v", err)
	}

	options := StartOptions{WireGuardConfigPath: "/tmp/wg.conf"}
	if err := options.Validate(); err != ErrLocalRelayEndpointMissing {
		t.Fatalf("missing relay endpoint returned wrong error: %v", err)
	}
}

func TestConfigWithWireGuardConfigUsesInterfaceAddresses(t *testing.T) {
	wireGuardConfig, err := ParseWireGuardConfig(strings.NewReader(`
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.250.10.8/32, 3d06:bad:b01:a::8/128

[Peer]
PublicKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=
AllowedIPs = 208.67.222.222/32, 2620:119:35::35/128
Endpoint = home.goodkind.io:51820
`))
	if err != nil {
		t.Fatalf("parse wireguard config: %v", err)
	}

	config := ConfigWithWireGuardConfig(DefaultConfig(), wireGuardConfig)

	if config.IPv4Address != "10.250.10.8" {
		t.Fatalf("unexpected IPv4 address: %s", config.IPv4Address)
	}
	if config.IPv4PeerAddress != "10.250.10.8" {
		t.Fatalf("unexpected IPv4 peer address: %s", config.IPv4PeerAddress)
	}
	if config.IPv4PrefixLength != 32 {
		t.Fatalf("unexpected IPv4 prefix: %d", config.IPv4PrefixLength)
	}
	if config.IPv6Address != "3d06:bad:b01:a::8" {
		t.Fatalf("unexpected IPv6 address: %s", config.IPv6Address)
	}
	if config.IPv6PrefixLength != 128 {
		t.Fatalf("unexpected IPv6 prefix: %d", config.IPv6PrefixLength)
	}
}

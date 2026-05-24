package tunnel

import "testing"

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

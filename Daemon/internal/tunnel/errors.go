package tunnel

import "errors"

var (
	// ErrWireGuardConfigPathMissing reports a start request without a WireGuard config file path.
	ErrWireGuardConfigPathMissing = errors.New("wireguard config path is not configured")
	// ErrLocalRelayEndpointMissing reports a start request without the Mac-to-iPhone relay endpoint.
	ErrLocalRelayEndpointMissing = errors.New("local relay endpoint is not configured")
	errUnsupportedPlatform       = errors.New("unsupported platform")
)

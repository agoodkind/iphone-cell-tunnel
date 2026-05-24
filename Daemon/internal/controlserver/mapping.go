package controlserver

import (
	"celltunnel/daemon/internal/discovery"
	"errors"
	"strings"

	controlv1 "celltunnel/daemon/internal/controlv1"
)

var (
	errRelaySelectionRequired = errors.New("relay selection required")
	errInvalidRelayEndpoint   = errors.New("invalid relay endpoint")
)

func startErrorResponse(
	code controlv1.ControlErrorCode,
	message string,
) *controlv1.StartTunnelResponse {
	return &controlv1.StartTunnelResponse{
		Result: &controlv1.StartTunnelResponse_Error{
			Error: controlError(code, message),
		},
	}
}

func discoveryErrorResponse(
	code controlv1.ControlErrorCode,
	message string,
) *controlv1.StartRelayDiscoveryResponse {
	return &controlv1.StartRelayDiscoveryResponse{
		Result: &controlv1.StartRelayDiscoveryResponse_Error{
			Error: controlError(code, message),
		},
	}
}

func stopDiscoveryErrorResponse(
	code controlv1.ControlErrorCode,
	message string,
) *controlv1.StopRelayDiscoveryResponse {
	return &controlv1.StopRelayDiscoveryResponse{
		Result: &controlv1.StopRelayDiscoveryResponse_Error{
			Error: controlError(code, message),
		},
	}
}

func selectDiscoveryErrorResponse(
	code controlv1.ControlErrorCode,
	message string,
) *controlv1.SelectRelayServiceResponse {
	return &controlv1.SelectRelayServiceResponse{
		Result: &controlv1.SelectRelayServiceResponse_Error{
			Error: controlError(code, message),
		},
	}
}

func controlError(code controlv1.ControlErrorCode, message string) *controlv1.ControlError {
	return &controlv1.ControlError{
		Code:    code,
		Message: strings.TrimSpace(message),
	}
}

func routeStateFromString(value string) controlv1.RouteState {
	if value == "installed" {
		return controlv1.RouteState_ROUTE_STATE_INSTALLED
	}
	return controlv1.RouteState_ROUTE_STATE_NOT_INSTALLED
}

func peerStateFromStatus(running bool, selectedRelay bool) controlv1.PeerState {
	if running {
		return controlv1.PeerState_PEER_STATE_WIREGUARD_CONFIGURED
	}
	if selectedRelay {
		return controlv1.PeerState_PEER_STATE_RELAY_SELECTED
	}
	return controlv1.PeerState_PEER_STATE_NOT_SELECTED
}

func discoveryPhaseToProto(phase discovery.Phase) controlv1.DiscoveryPhase {
	switch phase {
	case discovery.PhaseBrowsing:
		return controlv1.DiscoveryPhase_DISCOVERY_PHASE_BROWSING
	case discovery.PhaseStopped:
		return controlv1.DiscoveryPhase_DISCOVERY_PHASE_STOPPED
	case discovery.PhaseReady:
		return controlv1.DiscoveryPhase_DISCOVERY_PHASE_READY
	case discovery.PhaseFailed:
		return controlv1.DiscoveryPhase_DISCOVERY_PHASE_FAILED
	}

	return controlv1.DiscoveryPhase_DISCOVERY_PHASE_STOPPED
}

func relayEndpointToProto(endpoint *discovery.Endpoint) *controlv1.RelayEndpoint {
	if endpoint == nil {
		return nil
	}
	return &controlv1.RelayEndpoint{
		Host:          endpoint.Host,
		Port:          endpoint.Port,
		AddressFamily: addressFamilyToProto(endpoint.Family),
	}
}

func relayEndpointFromProto(endpoint *controlv1.RelayEndpoint) (discovery.Endpoint, error) {
	if endpoint == nil {
		return discovery.Endpoint{}, errRelaySelectionRequired
	}
	host := strings.TrimSpace(endpoint.GetHost())
	if host == "" || endpoint.GetPort() == 0 {
		return discovery.Endpoint{}, errInvalidRelayEndpoint
	}
	host = strings.TrimPrefix(strings.TrimSuffix(host, "]"), "[")
	return discovery.Endpoint{
		Host:   host,
		Port:   endpoint.GetPort(),
		Family: addressFamilyFromProto(endpoint.GetAddressFamily()),
	}, nil
}

func addressFamilyToProto(family discovery.AddressFamily) controlv1.AddressFamily {
	switch family {
	case discovery.AddressFamilyIPv4:
		return controlv1.AddressFamily_ADDRESS_FAMILY_IPV4
	case discovery.AddressFamilyIPv6:
		return controlv1.AddressFamily_ADDRESS_FAMILY_IPV6
	case discovery.AddressFamilyUnspecified:
		return controlv1.AddressFamily_ADDRESS_FAMILY_UNSPECIFIED
	}

	return controlv1.AddressFamily_ADDRESS_FAMILY_UNSPECIFIED
}

func addressFamilyFromProto(family controlv1.AddressFamily) discovery.AddressFamily {
	switch family {
	case controlv1.AddressFamily_ADDRESS_FAMILY_IPV4:
		return discovery.AddressFamilyIPv4
	case controlv1.AddressFamily_ADDRESS_FAMILY_IPV6:
		return discovery.AddressFamilyIPv6
	case controlv1.AddressFamily_ADDRESS_FAMILY_UNSPECIFIED:
		return discovery.AddressFamilyUnspecified
	}

	return discovery.AddressFamilyUnspecified
}

func runtimeErrorToProto(message string) *controlv1.ControlError {
	if strings.TrimSpace(message) == "" {
		return nil
	}
	return controlError(
		controlv1.ControlErrorCode_CONTROL_ERROR_CODE_RUNTIME_START_FAILURE,
		message,
	)
}

func controlErrorCodeForError(err error) controlv1.ControlErrorCode {
	switch {
	case errors.Is(err, errRelaySelectionRequired):
		return controlv1.ControlErrorCode_CONTROL_ERROR_CODE_RELAY_SELECTION_REQUIRED
	case errors.Is(err, errInvalidRelayEndpoint):
		return controlv1.ControlErrorCode_CONTROL_ERROR_CODE_INVALID_RELAY_ENDPOINT
	default:
		return controlv1.ControlErrorCode_CONTROL_ERROR_CODE_INTERNAL
	}
}

func cloneDiscoveryEndpoint(endpoint *discovery.Endpoint) *discovery.Endpoint {
	if endpoint == nil {
		return nil
	}
	selected := *endpoint
	return &selected
}

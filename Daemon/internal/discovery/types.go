// Package discovery provides daemon-owned native DNS-SD relay discovery types and state.
package discovery

import (
	"net"
	"slices"
	"strconv"
	"strings"
)

// AddressFamily identifies the preferred socket family for a relay endpoint.
type AddressFamily string

const (
	// AddressFamilyUnspecified marks a relay endpoint with no resolved address family.
	AddressFamilyUnspecified AddressFamily = "unspecified"
	// AddressFamilyIPv4 marks a relay endpoint resolved over IPv4.
	AddressFamilyIPv4 AddressFamily = "ipv4"
	// AddressFamilyIPv6 marks a relay endpoint resolved over IPv6.
	AddressFamilyIPv6 AddressFamily = "ipv6"
)

// Phase describes daemon-owned relay discovery activity.
type Phase string

const (
	// PhaseStopped marks relay discovery as inactive.
	PhaseStopped Phase = "stopped"
	// PhaseBrowsing marks relay discovery as actively browsing for services.
	PhaseBrowsing Phase = "browsing"
	// PhaseReady marks relay discovery as having at least one resolved relay.
	PhaseReady Phase = "ready"
	// PhaseFailed marks relay discovery as failed with a stored error message.
	PhaseFailed Phase = "failed"
)

// Endpoint is one resolved numeric relay address.
type Endpoint struct {
	Host   string
	Port   uint32
	Family AddressFamily
}

// SocketAddress renders the endpoint for tunnel runtime configuration.
func (endpoint Endpoint) SocketAddress() string {
	port := strconv.FormatUint(uint64(endpoint.Port), 10)
	if strings.HasPrefix(endpoint.Host, "usbmuxd:") {
		return endpoint.Host + ":" + port
	}
	return net.JoinHostPort(endpoint.Host, port)
}

// Identity is the stable daemon-side identity for one DNS-SD relay service.
type Identity struct {
	ServiceID      string
	ServiceName    string
	ServiceType    string
	Domain         string
	InterfaceIndex uint32
}

// Service is the daemon-owned discovery representation exposed over IPC.
type Service struct {
	Identity          Identity
	HostName          string
	Endpoints         []Endpoint
	PreferredEndpoint *Endpoint
	IsSelected        bool
}

// Snapshot is the daemon-owned discovery state exposed over IPC.
type Snapshot struct {
	Phase             Phase
	Services          []Service
	SelectedServiceID string
	SelectedEndpoint  *Endpoint
	LastError         string
}

// BrowseEvent is emitted from DNS-SD browse callbacks.
type BrowseEvent struct {
	Add            bool
	ServiceName    string
	ServiceType    string
	Domain         string
	InterfaceIndex uint32
}

// ResolveEvent is emitted from DNS-SD resolve callbacks.
type ResolveEvent struct {
	ServiceID string
	HostName  string
	Port      uint32
}

// AddressEvent is emitted from DNS-SD getaddrinfo callbacks.
type AddressEvent struct {
	ServiceID string
	Host      string
	Family    AddressFamily
}

func sortServices(services []Service) {
	slices.SortFunc(services, func(left Service, right Service) int {
		if left.Identity.ServiceName < right.Identity.ServiceName {
			return -1
		}
		if left.Identity.ServiceName > right.Identity.ServiceName {
			return 1
		}
		if left.Identity.ServiceID < right.Identity.ServiceID {
			return -1
		}
		if left.Identity.ServiceID > right.Identity.ServiceID {
			return 1
		}
		return 0
	})
}

func preferredEndpoint(endpoints []Endpoint) *Endpoint {
	for _, endpoint := range endpoints {
		if endpoint.Family == AddressFamilyIPv6 {
			selected := endpoint
			return &selected
		}
	}
	for _, endpoint := range endpoints {
		if endpoint.Family == AddressFamilyIPv4 {
			selected := endpoint
			return &selected
		}
	}
	return nil
}

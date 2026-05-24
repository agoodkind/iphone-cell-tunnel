package discovery

import "testing"

func TestStateStorePrefersIPv6AndAutoSelectsSingleService(t *testing.T) {
	store := newStateStore()
	store.beginBrowsing()

	serviceID := store.applyBrowse(BrowseEvent{
		Add:            true,
		ServiceName:    "CellTunnelPhone",
		ServiceType:    "_cellrelay._tcp",
		Domain:         "local.",
		InterfaceIndex: 12,
	})
	store.applyResolve(ResolveEvent{
		ServiceID: serviceID,
		HostName:  "CellTunnelPhone.local",
		Port:      5354,
	})
	store.applyAddress(AddressEvent{
		ServiceID: serviceID,
		Host:      "192.0.2.4",
		Family:    AddressFamilyIPv4,
	})
	store.applyAddress(AddressEvent{
		ServiceID: serviceID,
		Host:      "fd00::4",
		Family:    AddressFamilyIPv6,
	})

	snapshot := store.snapshot()
	if snapshot.Phase != PhaseReady {
		t.Fatalf("phase = %q, want %q", snapshot.Phase, PhaseReady)
	}
	if snapshot.SelectedServiceID != serviceID {
		t.Fatalf("selected service = %q, want %q", snapshot.SelectedServiceID, serviceID)
	}
	if snapshot.SelectedEndpoint == nil {
		t.Fatal("selected endpoint is nil")
	}
	if snapshot.SelectedEndpoint.Family != AddressFamilyIPv6 {
		t.Fatalf("selected family = %q, want %q", snapshot.SelectedEndpoint.Family, AddressFamilyIPv6)
	}
	if got := snapshot.SelectedEndpoint.SocketAddress(); got != "[fd00::4]:5354" {
		t.Fatalf("selected endpoint = %q, want %q", got, "[fd00::4]:5354")
	}
}

func TestStateStoreRemovesSelectedService(t *testing.T) {
	store := newStateStore()
	store.beginBrowsing()

	serviceID := store.applyBrowse(BrowseEvent{
		Add:            true,
		ServiceName:    "CellTunnelPhone",
		ServiceType:    "_cellrelay._tcp",
		Domain:         "local.",
		InterfaceIndex: 7,
	})
	store.applyResolve(ResolveEvent{
		ServiceID: serviceID,
		HostName:  "CellTunnelPhone.local",
		Port:      5354,
	})
	store.applyAddress(AddressEvent{
		ServiceID: serviceID,
		Host:      "fd00::7",
		Family:    AddressFamilyIPv6,
	})

	store.applyBrowse(BrowseEvent{
		Add:            false,
		ServiceName:    "CellTunnelPhone",
		ServiceType:    "_cellrelay._tcp",
		Domain:         "local.",
		InterfaceIndex: 7,
	})

	snapshot := store.snapshot()
	if snapshot.SelectedServiceID != "" {
		t.Fatalf("selected service = %q, want empty", snapshot.SelectedServiceID)
	}
	if snapshot.SelectedEndpoint != nil {
		t.Fatalf("selected endpoint = %#v, want nil", snapshot.SelectedEndpoint)
	}
}

func TestStateStoreRequiresExplicitSelectionForMultipleServices(t *testing.T) {
	store := newStateStore()
	store.beginBrowsing()

	firstServiceID := store.applyBrowse(BrowseEvent{
		Add:            true,
		ServiceName:    "CellTunnelPhone-A",
		ServiceType:    "_cellrelay._tcp",
		Domain:         "local.",
		InterfaceIndex: 1,
	})
	store.applyResolve(ResolveEvent{
		ServiceID: firstServiceID,
		HostName:  "CellTunnelPhone-A.local",
		Port:      5354,
	})
	store.applyAddress(AddressEvent{
		ServiceID: firstServiceID,
		Host:      "fd00::a",
		Family:    AddressFamilyIPv6,
	})

	secondServiceID := store.applyBrowse(BrowseEvent{
		Add:            true,
		ServiceName:    "CellTunnelPhone-B",
		ServiceType:    "_cellrelay._tcp",
		Domain:         "local.",
		InterfaceIndex: 2,
	})
	store.applyResolve(ResolveEvent{
		ServiceID: secondServiceID,
		HostName:  "CellTunnelPhone-B.local",
		Port:      5355,
	})
	store.applyAddress(AddressEvent{
		ServiceID: secondServiceID,
		Host:      "fd00::b",
		Family:    AddressFamilyIPv6,
	})

	snapshot := store.snapshot()
	if snapshot.SelectedEndpoint != nil {
		t.Fatalf("selected endpoint = %#v, want nil", snapshot.SelectedEndpoint)
	}
	if !store.selectService(secondServiceID) {
		t.Fatal("select service returned false")
	}
	snapshot = store.snapshot()
	if snapshot.SelectedServiceID != secondServiceID {
		t.Fatalf("selected service = %q, want %q", snapshot.SelectedServiceID, secondServiceID)
	}
}

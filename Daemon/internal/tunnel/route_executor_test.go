package tunnel

import (
	"context"
	"errors"
	"testing"

	"golang.org/x/net/route"
	"golang.org/x/sys/unix"
)

type recordingNetworkManager struct {
	relayInterface string
	operations     []NetworkOperationKind
	operationText  []string
	queries        []LocalRelayPreservation
	applyErr       error
}

func (manager *recordingNetworkManager) ConfigureIPv4Address(ctx context.Context, operation NetworkOperation) error {
	return manager.record(operation)
}

func (manager *recordingNetworkManager) ConfigureIPv6Address(ctx context.Context, operation NetworkOperation) error {
	return manager.record(operation)
}

func (manager *recordingNetworkManager) ConfigureInterfaceMTUAndUp(
	ctx context.Context,
	operation NetworkOperation,
) error {
	return manager.record(operation)
}

func (manager *recordingNetworkManager) AddRoute(ctx context.Context, operation NetworkOperation) error {
	return manager.record(operation)
}

func (manager *recordingNetworkManager) DeleteRoute(ctx context.Context, operation NetworkOperation) error {
	return manager.record(operation)
}

func (manager *recordingNetworkManager) FindRouteInterface(
	ctx context.Context,
	preservation LocalRelayPreservation,
) (string, error) {
	manager.queries = append(manager.queries, preservation)
	if manager.relayInterface == "" {
		return "", errors.New("missing relay interface")
	}
	return manager.relayInterface, nil
}

func (manager *recordingNetworkManager) AddLocalRelayRoute(ctx context.Context, operation NetworkOperation) error {
	return manager.record(operation)
}

func (manager *recordingNetworkManager) DeleteLocalRelayRoute(ctx context.Context, operation NetworkOperation) error {
	return manager.record(operation)
}

func (manager *recordingNetworkManager) record(operation NetworkOperation) error {
	manager.operations = append(manager.operations, operation.Kind)
	manager.operationText = append(manager.operationText, operation.String())
	return manager.applyErr
}

func TestRouteExecutorPreservesLocalRelayBeforeDefaultRoutes(t *testing.T) {
	manager := &recordingNetworkManager{relayInterface: "en0"}
	executor := NewRouteExecutor(manager)
	config := DefaultConfig()
	config.LocalRelayEndpoint = "192.0.2.55:51820"
	plan := BuildRoutePlan(config, testWireGuardConfigModel(), "utun42")

	if err := executor.Install(context.Background(), plan); err != nil {
		t.Fatalf("install routes: %v", err)
	}

	if len(manager.queries) != 1 {
		t.Fatalf("unexpected route query count: %#v", manager.queries)
	}
	if manager.queries[0].EndpointHost != "192.0.2.55" {
		t.Fatalf("unexpected route query: %#v", manager.queries[0])
	}
	expectedOperations := []NetworkOperationKind{
		networkOperationAddIPv4RelayHost,
		networkOperationIPv4Address,
		networkOperationIPv6Address,
		networkOperationInterfaceMTUAndUp,
		networkOperationAddIPv4Route,
		networkOperationAddIPv6Route,
	}
	assertOperationOrder(t, manager.operations, expectedOperations)
	if manager.operationText[0] != "operation=add-ipv4-relay-host host=192.0.2.55 relay_interface=en0 family=4" {
		t.Fatalf("local relay route was not installed first: %#v", manager.operationText)
	}
}

func TestRouteExecutorUsesScopedRelayInterfaceWithoutRouteQuery(t *testing.T) {
	manager := &recordingNetworkManager{}
	executor := NewRouteExecutor(manager)
	config := DefaultConfig()
	config.LocalRelayEndpoint = "[fe80::1%en11]:57400"
	plan := BuildRoutePlan(config, testWireGuardConfigModel(), "utun42")

	if err := executor.Install(context.Background(), plan); err != nil {
		t.Fatalf("install routes: %v", err)
	}

	if len(manager.queries) != 0 {
		t.Fatalf("unexpected scoped route query: %#v", manager.queries)
	}
	expectedOperations := []NetworkOperationKind{
		networkOperationAddIPv6RelayHost,
		networkOperationIPv4Address,
		networkOperationIPv6Address,
		networkOperationInterfaceMTUAndUp,
		networkOperationAddIPv4Route,
		networkOperationAddIPv6Route,
	}
	assertOperationOrder(t, manager.operations, expectedOperations)
	if manager.operationText[0] != "operation=add-ipv6-relay-host host=fe80::1 relay_interface=en11 family=6" {
		t.Fatalf("scoped relay route did not preserve interface: %#v", manager.operationText)
	}
}

func TestRouteExecutorRemovesDefaultRoutesAndLocalRelayRoute(t *testing.T) {
	manager := &recordingNetworkManager{}
	executor := NewRouteExecutor(manager)
	config := DefaultConfig()
	config.LocalRelayEndpoint = "[2001:db8::55]:51820"
	plan := BuildRoutePlan(config, testWireGuardConfigModel(), "utun42")

	if err := executor.Remove(context.Background(), plan); err != nil {
		t.Fatalf("remove routes: %v", err)
	}

	expectedOperations := []NetworkOperationKind{
		networkOperationDeleteIPv4Route,
		networkOperationDeleteIPv6Route,
		networkOperationDeleteIPv6RelayHost,
	}
	assertOperationOrder(t, manager.operations, expectedOperations)
	if !hasOperationText(manager.operationText, "operation=delete-ipv6-relay-host host=2001:db8::55 family=6") {
		t.Fatalf("missing local relay IPv6 route removal: %#v", manager.operationText)
	}
}

func TestRouteExecutorRemovesScopedIPv6LocalRelayRoute(t *testing.T) {
	manager := &recordingNetworkManager{}
	executor := NewRouteExecutor(manager)
	config := DefaultConfig()
	config.LocalRelayEndpoint = "[fe80::1%en11]:57400"
	plan := BuildRoutePlan(config, testWireGuardConfigModel(), "utun42")

	if err := executor.Remove(context.Background(), plan); err != nil {
		t.Fatalf("remove routes: %v", err)
	}

	if !hasOperationText(
		manager.operationText,
		"operation=delete-ipv6-relay-host host=fe80::1 relay_interface=en11 family=6",
	) {
		t.Fatalf("missing scoped local relay IPv6 route removal: %#v", manager.operationText)
	}
}

func TestRouteExecutorRollsBackLocalRelayWhenInstallFails(t *testing.T) {
	manager := &recordingNetworkManager{
		relayInterface: "en0",
		applyErr:       errors.New("native mutation failed"),
	}
	executor := NewRouteExecutor(manager)
	config := DefaultConfig()
	config.LocalRelayEndpoint = "192.0.2.55:51820"
	plan := BuildRoutePlan(config, testWireGuardConfigModel(), "utun42")

	err := executor.Install(context.Background(), plan)
	if err == nil {
		t.Fatal("expected install failure")
	}
	expectedOperations := []NetworkOperationKind{
		networkOperationAddIPv4RelayHost,
	}
	assertOperationOrder(t, manager.operations, expectedOperations)
}

func TestDeleteLocalRelayRouteMessageDoesNotRequireInterface(t *testing.T) {
	operation := NetworkOperation{
		Kind:          networkOperationDeleteIPv4RelayHost,
		EndpointHost:  "192.0.2.55",
		AddressFamily: RelayAddressFamilyIPv4,
	}

	message, err := routeMutationMessage(unix.RTM_DELETE, operation)
	if err != nil {
		t.Fatalf("build delete route message: %v", err)
	}
	if message.Index != 0 {
		t.Fatalf("delete route message unexpectedly scoped to interface: %#v", message)
	}
	if message.Addrs[unix.RTAX_GATEWAY] != nil {
		t.Fatalf("delete route message unexpectedly has gateway: %#v", message.Addrs[unix.RTAX_GATEWAY])
	}
	destination, ok := message.Addrs[unix.RTAX_DST].(*route.Inet4Addr)
	if !ok {
		t.Fatalf("delete route destination is not IPv4: %#v", message.Addrs[unix.RTAX_DST])
	}
	if destination.IP != [4]byte{192, 0, 2, 55} {
		t.Fatalf("unexpected delete route destination: %#v", destination.IP)
	}
}

func assertOperationOrder(t *testing.T, operations []NetworkOperationKind, expected []NetworkOperationKind) {
	t.Helper()
	if len(operations) != len(expected) {
		t.Fatalf("unexpected operation count: got %#v want %#v", operations, expected)
	}
	for index, expectedOperation := range expected {
		if operations[index] != expectedOperation {
			t.Fatalf("unexpected operation at %d: got %#v want %#v", index, operations, expected)
		}
	}
}

func hasOperationText(operations []string, expected string) bool {
	for _, operation := range operations {
		if operation == expected {
			return true
		}
	}
	return false
}

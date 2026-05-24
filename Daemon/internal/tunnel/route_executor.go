package tunnel

import (
	"context"
	"errors"
	"fmt"
	"math"
	"net"
	"net/netip"
	"sync/atomic"
	"time"
	"unsafe"

	"golang.org/x/net/route"
	"golang.org/x/sys/unix"
)

const (
	networkMutationTimeout = 10 * time.Second
	ioctlIn                = 0x80000000
	ioctlParameterMask     = 0x1fff
	nd6InfiniteLifetime    = 0xffffffff
	ipv6NoDadFlag          = 0x20
	routeSenderID          = 1
)

var (
	errUnsupportedNetworkOperation = errors.New("unsupported network operation")
	errRouteSocketResponseMissing  = errors.New("route socket response missing")
	errRouteSocketResponseInvalid  = errors.New("route socket response invalid")
	routeSequence                  atomic.Int32
)

// NetworkManager applies typed native network mutations.
type NetworkManager interface {
	ConfigureIPv4Address(ctx context.Context, operation NetworkOperation) error
	ConfigureIPv6Address(ctx context.Context, operation NetworkOperation) error
	ConfigureInterfaceMTUAndUp(ctx context.Context, operation NetworkOperation) error
	AddDefaultRoute(ctx context.Context, operation NetworkOperation) error
	DeleteDefaultRoute(ctx context.Context, operation NetworkOperation) error
	FindRouteInterface(ctx context.Context, preservation LocalRelayPreservation) (string, error)
	AddLocalRelayRoute(ctx context.Context, operation NetworkOperation) error
	DeleteLocalRelayRoute(ctx context.Context, operation NetworkOperation) error
}

// DarwinNetworkManager applies route and interface mutations through route sockets and ioctls.
type DarwinNetworkManager struct{}

type ipv4AliasRequest struct {
	Name      [unix.IFNAMSIZ]byte
	Address   unix.RawSockaddrInet4
	Broadcast unix.RawSockaddrInet4
	Mask      unix.RawSockaddrInet4
}

type interfaceFlagRequest struct {
	Name  [unix.IFNAMSIZ]byte
	Flags int16
	Pad   [14]byte
}

type ipv6AddressLifetime struct {
	Expire            int64
	Preferred         int64
	ValidLifetime     uint32
	PreferredLifetime uint32
}

type ipv6AliasRequest struct {
	Name        [unix.IFNAMSIZ]byte
	Address     unix.RawSockaddrInet6
	Destination unix.RawSockaddrInet6
	PrefixMask  unix.RawSockaddrInet6
	Flags       int32
	Lifetime    ipv6AddressLifetime
}

// ConfigureIPv4Address assigns the configured IPv4 address to the interface with SIOCAIFADDR.
func (manager DarwinNetworkManager) ConfigureIPv4Address(ctx context.Context, operation NetworkOperation) error {
	if err := ctx.Err(); err != nil {
		logger.ErrorContext(ctx, "ipv4 address setup cancelled", "err", err)
		return fmt.Errorf("cancel ipv4 address setup: %w", err)
	}
	logger.InfoContext(ctx, "ipv4 address setup starting", "interface_name", operation.InterfaceName)
	address, err := parseIPv4Address(operation.Address)
	if err != nil {
		logger.ErrorContext(ctx, "ipv4 address parse failed", "err", err)
		return err
	}
	peerAddress, err := parseIPv4Address(operation.PeerAddress)
	if err != nil {
		logger.ErrorContext(ctx, "ipv4 peer address parse failed", "err", err)
		return err
	}
	mask, err := ipv4PrefixMask(operation.PrefixLength)
	if err != nil {
		logger.ErrorContext(ctx, "ipv4 prefix mask failed", "err", err)
		return err
	}
	request := ipv4AliasRequest{
		Address:   rawIPv4Sockaddr(address),
		Broadcast: rawIPv4Sockaddr(peerAddress),
		Mask:      rawIPv4Sockaddr(mask),
	}
	if err := copyInterfaceName(request.Name[:], operation.InterfaceName); err != nil {
		logger.ErrorContext(ctx, "ipv4 interface name invalid", "err", err)
		return err
	}
	if err := ioctlSocket(unix.AF_INET, unix.SIOCAIFADDR, unsafe.Pointer(&request)); err != nil {
		logger.ErrorContext(ctx, "ipv4 address setup ioctl failed", "err", err, "interface_name", operation.InterfaceName)
		return fmt.Errorf("configure ipv4 address: %w", err)
	}
	logger.InfoContext(ctx, "ipv4 address setup completed", "interface_name", operation.InterfaceName)
	return nil
}

// ConfigureIPv6Address assigns the configured IPv6 address to the interface with SIOCAIFADDR_IN6.
func (manager DarwinNetworkManager) ConfigureIPv6Address(ctx context.Context, operation NetworkOperation) error {
	if err := ctx.Err(); err != nil {
		logger.ErrorContext(ctx, "ipv6 address setup cancelled", "err", err)
		return fmt.Errorf("cancel ipv6 address setup: %w", err)
	}
	logger.InfoContext(ctx, "ipv6 address setup starting", "interface_name", operation.InterfaceName)
	address, err := parseIPv6Address(operation.Address)
	if err != nil {
		logger.ErrorContext(ctx, "ipv6 address parse failed", "err", err)
		return err
	}
	mask, err := ipv6PrefixMask(operation.PrefixLength)
	if err != nil {
		logger.ErrorContext(ctx, "ipv6 prefix mask failed", "err", err)
		return err
	}
	request := ipv6AliasRequest{
		Address:    rawIPv6Sockaddr(address),
		PrefixMask: rawIPv6Sockaddr(mask),
		Flags:      ipv6NoDadFlag,
		Lifetime: ipv6AddressLifetime{
			ValidLifetime:     nd6InfiniteLifetime,
			PreferredLifetime: nd6InfiniteLifetime,
		},
	}
	if err := copyInterfaceName(request.Name[:], operation.InterfaceName); err != nil {
		logger.ErrorContext(ctx, "ipv6 interface name invalid", "err", err)
		return err
	}
	requestCode := ioctlWriteRequest('i', 26, unsafe.Sizeof(request))
	if err := ioctlSocket(unix.AF_INET6, requestCode, unsafe.Pointer(&request)); err != nil {
		logger.ErrorContext(ctx, "ipv6 address setup ioctl failed", "err", err, "interface_name", operation.InterfaceName)
		return fmt.Errorf("configure ipv6 address: %w", err)
	}
	logger.InfoContext(ctx, "ipv6 address setup completed", "interface_name", operation.InterfaceName)
	return nil
}

// ConfigureInterfaceMTUAndUp applies MTU and IFF_UP through native interface ioctls.
func (manager DarwinNetworkManager) ConfigureInterfaceMTUAndUp(ctx context.Context, operation NetworkOperation) error {
	if err := ctx.Err(); err != nil {
		logger.ErrorContext(ctx, "interface mtu and up setup cancelled", "err", err)
		return fmt.Errorf("cancel interface mtu and up setup: %w", err)
	}
	logger.InfoContext(ctx, "interface mtu and up setup starting", "interface_name", operation.InterfaceName, "mtu", operation.MTU)
	fd, err := unix.Socket(unix.AF_INET, unix.SOCK_DGRAM, 0)
	if err != nil {
		logger.ErrorContext(ctx, "interface socket open failed", "err", err)
		return fmt.Errorf("open interface socket: %w", err)
	}
	defer closeFileDescriptor("interface socket", fd)

	mtuValue, err := boundedMTU(operation.MTU)
	if err != nil {
		logger.ErrorContext(ctx, "interface mtu invalid", "err", err, "mtu", operation.MTU)
		return err
	}
	mtuRequest := unix.IfreqMTU{MTU: mtuValue}
	if err := copyInterfaceName(mtuRequest.Name[:], operation.InterfaceName); err != nil {
		logger.ErrorContext(ctx, "mtu interface name invalid", "err", err)
		return err
	}
	if err := unix.IoctlSetIfreqMTU(fd, &mtuRequest); err != nil {
		logger.ErrorContext(ctx, "interface mtu ioctl failed", "err", err, "interface_name", operation.InterfaceName)
		return fmt.Errorf("set interface mtu: %w", err)
	}

	flagRequest := interfaceFlagRequest{}
	if err := copyInterfaceName(flagRequest.Name[:], operation.InterfaceName); err != nil {
		logger.ErrorContext(ctx, "flags interface name invalid", "err", err)
		return err
	}
	if err := rawIoctl(fd, unix.SIOCGIFFLAGS, unsafe.Pointer(&flagRequest)); err != nil {
		logger.ErrorContext(ctx, "interface flags read ioctl failed", "err", err, "interface_name", operation.InterfaceName)
		return fmt.Errorf("read interface flags: %w", err)
	}
	flagRequest.Flags |= unix.IFF_UP
	if err := rawIoctl(fd, unix.SIOCSIFFLAGS, unsafe.Pointer(&flagRequest)); err != nil {
		logger.ErrorContext(ctx, "interface flags write ioctl failed", "err", err, "interface_name", operation.InterfaceName)
		return fmt.Errorf("set interface up: %w", err)
	}
	logger.InfoContext(ctx, "interface mtu and up setup completed", "interface_name", operation.InterfaceName)
	return nil
}

// AddDefaultRoute installs a default IPv4 or IPv6 interface route through a routing socket.
func (manager DarwinNetworkManager) AddDefaultRoute(ctx context.Context, operation NetworkOperation) error {
	logger.InfoContext(ctx, "default route add starting", "operation", operation.Kind, "interface_name", operation.InterfaceName)
	if err := manager.writeRouteMutation(ctx, unix.RTM_ADD, operation); err != nil {
		logger.ErrorContext(ctx, "default route add failed", "err", err, "operation", operation.Kind)
		return err
	}
	logger.InfoContext(ctx, "default route add completed", "operation", operation.Kind, "interface_name", operation.InterfaceName)
	return nil
}

// DeleteDefaultRoute removes a default IPv4 or IPv6 interface route through a routing socket.
func (manager DarwinNetworkManager) DeleteDefaultRoute(ctx context.Context, operation NetworkOperation) error {
	logger.InfoContext(ctx, "default route delete starting", "operation", operation.Kind, "interface_name", operation.InterfaceName)
	if err := manager.writeRouteMutation(ctx, unix.RTM_DELETE, operation); err != nil {
		logger.ErrorContext(ctx, "default route delete failed", "err", err, "operation", operation.Kind)
		return err
	}
	logger.InfoContext(ctx, "default route delete completed", "operation", operation.Kind, "interface_name", operation.InterfaceName)
	return nil
}

// FindRouteInterface queries the current route for the local relay endpoint.
func (manager DarwinNetworkManager) FindRouteInterface(ctx context.Context, preservation LocalRelayPreservation) (string, error) {
	if err := ctx.Err(); err != nil {
		logger.ErrorContext(ctx, "local relay route query cancelled", "err", err)
		return "", fmt.Errorf("cancel local relay route query: %w", err)
	}
	logger.InfoContext(ctx, "local relay route query starting", "endpoint_family", preservation.AddressFamily)
	destination, err := parseRelayAddress(preservation)
	if err != nil {
		logger.ErrorContext(ctx, "local relay route query address parse failed", "err", err)
		return "", err
	}
	message := route.RouteMessage{
		Version: unix.RTM_VERSION,
		Type:    unix.RTM_GET,
		ID:      routeSenderID,
		Seq:     nextRouteSequence(),
		Addrs: []route.Addr{
			destination,
		},
	}
	response, err := writeRouteMessage(&message, true)
	if err != nil {
		logger.ErrorContext(ctx, "local relay route query failed", "err", err)
		return "", fmt.Errorf("query local relay route: %w", err)
	}
	interfaceName, err := routeMessageInterfaceName(response)
	if err != nil {
		logger.ErrorContext(ctx, "local relay route query interface parse failed", "err", err)
		return "", err
	}
	logger.InfoContext(ctx, "local relay route query completed", "interface_name", interfaceName)
	return interfaceName, nil
}

// AddLocalRelayRoute installs a host route that preserves the local iPhone relay path.
func (manager DarwinNetworkManager) AddLocalRelayRoute(ctx context.Context, operation NetworkOperation) error {
	logger.InfoContext(ctx, "local relay route add starting", "endpoint_family", operation.AddressFamily)
	if err := manager.writeRouteMutation(ctx, unix.RTM_ADD, operation); err != nil {
		logger.ErrorContext(ctx, "local relay route add failed", "err", err)
		return err
	}
	logger.InfoContext(ctx, "local relay route add completed", "endpoint_family", operation.AddressFamily)
	return nil
}

// DeleteLocalRelayRoute removes the host route that preserved the local iPhone relay path.
func (manager DarwinNetworkManager) DeleteLocalRelayRoute(ctx context.Context, operation NetworkOperation) error {
	logger.InfoContext(ctx, "local relay route delete starting", "endpoint_family", operation.AddressFamily)
	if err := manager.writeRouteMutation(ctx, unix.RTM_DELETE, operation); err != nil {
		logger.ErrorContext(ctx, "local relay route delete failed", "err", err)
		return err
	}
	logger.InfoContext(ctx, "local relay route delete completed", "endpoint_family", operation.AddressFamily)
	return nil
}

func (manager DarwinNetworkManager) writeRouteMutation(
	ctx context.Context,
	routeMessageType int,
	operation NetworkOperation,
) error {
	if err := ctx.Err(); err != nil {
		logger.ErrorContext(ctx, "route socket mutation cancelled", "err", err)
		return fmt.Errorf("cancel route socket mutation: %w", err)
	}
	message, err := routeMutationMessage(routeMessageType, operation)
	if err != nil {
		logger.ErrorContext(ctx, "route socket message build failed", "err", err, "operation", operation.Kind)
		return err
	}
	_, err = writeRouteMessage(message, false)
	if err != nil {
		logger.ErrorContext(ctx, "route socket mutation write failed", "err", err, "operation", operation.Kind)
		return err
	}
	return nil
}

func routeMutationMessage(routeMessageType int, operation NetworkOperation) (*route.RouteMessage, error) {
	destination, netmask, err := routeDestinationAndMask(operation)
	if err != nil {
		return nil, err
	}
	addrs := make([]route.Addr, unix.RTAX_MAX)
	addrs[unix.RTAX_DST] = destination
	if netmask != nil {
		addrs[unix.RTAX_NETMASK] = netmask
	}
	routeIndex := 0
	if routeOperationNeedsInterface(operation.Kind) {
		networkInterface, err := routeOperationInterface(operation)
		if err != nil {
			return nil, err
		}
		routeIndex = networkInterface.Index
		addrs[unix.RTAX_GATEWAY] = &route.LinkAddr{Index: networkInterface.Index, Name: networkInterface.Name}
	}
	flags := unix.RTF_UP | unix.RTF_STATIC
	if isHostRoute(operation.Kind) {
		flags |= unix.RTF_HOST
	}
	return &route.RouteMessage{
		Version: unix.RTM_VERSION,
		Type:    routeMessageType,
		Flags:   flags,
		Index:   routeIndex,
		ID:      routeSenderID,
		Seq:     nextRouteSequence(),
		Addrs:   addrs,
	}, nil
}

func routeOperationInterface(operation NetworkOperation) (*net.Interface, error) {
	interfaceName := operation.InterfaceName
	if operation.RelayInterface != "" {
		interfaceName = operation.RelayInterface
	}
	networkInterface, err := net.InterfaceByName(interfaceName)
	if err != nil {
		logger.Error("route interface resolution failed", "err", err, "interface_name", interfaceName)
		return nil, fmt.Errorf("resolve route interface: %w", err)
	}
	return networkInterface, nil
}

func routeOperationNeedsInterface(kind NetworkOperationKind) bool {
	return kind == networkOperationAddIPv4Default ||
		kind == networkOperationAddIPv6Default ||
		kind == networkOperationDeleteIPv4Default ||
		kind == networkOperationDeleteIPv6Default ||
		kind == networkOperationAddIPv4RelayHost ||
		kind == networkOperationAddIPv6RelayHost
}

func routeDestinationAndMask(operation NetworkOperation) (route.Addr, route.Addr, error) {
	if operation.AddressFamily == RelayAddressFamilyIPv6 {
		destination, err := ipv6RouteDestination(operation)
		if err != nil {
			return nil, nil, err
		}
		if isHostRoute(operation.Kind) {
			return destination, nil, nil
		}
		return destination, &route.Inet6Addr{}, nil
	}
	destination, err := ipv4RouteDestination(operation)
	if err != nil {
		return nil, nil, err
	}
	if isHostRoute(operation.Kind) {
		return destination, nil, nil
	}
	return destination, &route.Inet4Addr{}, nil
}

func ipv4RouteDestination(operation NetworkOperation) (route.Addr, error) {
	address := "0.0.0.0"
	if operation.EndpointHost != "" {
		address = operation.EndpointHost
	}
	parsedAddress, err := parseIPv4Address(address)
	if err != nil {
		return nil, err
	}
	return &route.Inet4Addr{IP: parsedAddress}, nil
}

func ipv6RouteDestination(operation NetworkOperation) (route.Addr, error) {
	address := "::"
	if operation.EndpointHost != "" {
		address = operation.EndpointHost
	}
	parsedAddress, err := parseIPv6Address(address)
	if err != nil {
		return nil, err
	}
	return &route.Inet6Addr{IP: parsedAddress}, nil
}

func writeRouteMessage(message *route.RouteMessage, expectResponse bool) (*route.RouteMessage, error) {
	fd, err := unix.Socket(unix.AF_ROUTE, unix.SOCK_RAW, unix.AF_UNSPEC)
	if err != nil {
		logger.Error("route socket open failed", "err", err)
		return nil, fmt.Errorf("open route socket: %w", err)
	}
	defer closeFileDescriptor("route socket", fd)

	wireMessage, err := message.Marshal()
	if err != nil {
		logger.Error("route message marshal failed", "err", err)
		return nil, fmt.Errorf("marshal route message: %w", err)
	}
	if _, err := unix.Write(fd, wireMessage); err != nil {
		logger.Error("route message write failed", "err", err)
		return nil, fmt.Errorf("write route message: %w", err)
	}
	if !expectResponse {
		return nil, nil
	}
	buffer := make([]byte, 4096)
	count, err := unix.Read(fd, buffer)
	if err != nil {
		logger.Error("route message read failed", "err", err)
		return nil, fmt.Errorf("read route message: %w", err)
	}
	messages, err := route.ParseRIB(route.RIBTypeRoute, buffer[:count])
	if err != nil {
		logger.Error("route response parse failed", "err", err)
		return nil, fmt.Errorf("parse route response: %w", err)
	}
	if len(messages) == 0 {
		return nil, errRouteSocketResponseMissing
	}
	routeMessage, ok := messages[0].(*route.RouteMessage)
	if !ok {
		return nil, errRouteSocketResponseInvalid
	}
	if routeMessage.Err != nil {
		return nil, routeMessage.Err
	}
	return routeMessage, nil
}

func routeMessageInterfaceName(message *route.RouteMessage) (string, error) {
	if message.Index > 0 {
		networkInterface, err := net.InterfaceByIndex(message.Index)
		if err == nil {
			return networkInterface.Name, nil
		}
	}
	for _, address := range message.Addrs {
		linkAddress, ok := address.(*route.LinkAddr)
		if ok && linkAddress.Name != "" {
			return linkAddress.Name, nil
		}
	}
	return "", errors.New("route response interface was not found")
}

func parseRelayAddress(preservation LocalRelayPreservation) (route.Addr, error) {
	if preservation.AddressFamily == RelayAddressFamilyIPv6 {
		address, err := parseIPv6Address(preservation.EndpointHost)
		if err != nil {
			return nil, err
		}
		return &route.Inet6Addr{IP: address}, nil
	}
	address, err := parseIPv4Address(preservation.EndpointHost)
	if err != nil {
		return nil, err
	}
	return &route.Inet4Addr{IP: address}, nil
}

func isHostRoute(kind NetworkOperationKind) bool {
	return kind == networkOperationAddIPv4RelayHost ||
		kind == networkOperationAddIPv6RelayHost ||
		kind == networkOperationDeleteIPv4RelayHost ||
		kind == networkOperationDeleteIPv6RelayHost
}

func ioctlSocket(addressFamily int, request uintptr, pointer unsafe.Pointer) error {
	fd, err := unix.Socket(addressFamily, unix.SOCK_DGRAM, 0)
	if err != nil {
		logger.Error("ioctl socket open failed", "err", err)
		return fmt.Errorf("open ioctl socket: %w", err)
	}
	defer closeFileDescriptor("ioctl socket", fd)
	return rawIoctl(fd, request, pointer)
}

func rawIoctl(fd int, request uintptr, pointer unsafe.Pointer) error {
	return nativeIoctl(fd, request, pointer)
}

func ioctlWriteRequest(group byte, number byte, size uintptr) uintptr {
	return ioctlIn | ((size & ioctlParameterMask) << 16) | (uintptr(group) << 8) | uintptr(number)
}

func closeFileDescriptor(operation string, fd int) {
	if err := unix.Close(fd); err != nil {
		logger.Error(operation+" close failed", "err", err)
	}
}

func copyInterfaceName(destination []byte, interfaceName string) error {
	if len(interfaceName) >= len(destination) {
		return fmt.Errorf("interface name too long: %s", interfaceName)
	}
	copy(destination, interfaceName)
	return nil
}

func boundedMTU(mtu int) (int32, error) {
	if mtu <= 0 {
		return 0, fmt.Errorf("invalid mtu: %d", mtu)
	}
	if mtu > math.MaxInt32 {
		return 0, fmt.Errorf("mtu exceeds int32: %d", mtu)
	}
	return int32(mtu), nil
}

func nextRouteSequence() int {
	return int(routeSequence.Add(1))
}

func parseIPv4Address(rawAddress string) ([4]byte, error) {
	address, err := netip.ParseAddr(rawAddress)
	if err != nil {
		logger.Error("ipv4 address parse failed", "err", err)
		return [4]byte{}, fmt.Errorf("parse ipv4 address: %w", err)
	}
	if !address.Is4() {
		return [4]byte{}, fmt.Errorf("address is not ipv4: %s", rawAddress)
	}
	return address.As4(), nil
}

func parseIPv6Address(rawAddress string) ([16]byte, error) {
	address, err := netip.ParseAddr(rawAddress)
	if err != nil {
		logger.Error("ipv6 address parse failed", "err", err)
		return [16]byte{}, fmt.Errorf("parse ipv6 address: %w", err)
	}
	if !address.Is6() {
		return [16]byte{}, fmt.Errorf("address is not ipv6: %s", rawAddress)
	}
	return address.As16(), nil
}

func ipv4PrefixMask(prefixLength int) ([4]byte, error) {
	mask := net.CIDRMask(prefixLength, 32)
	if len(mask) != net.IPv4len {
		return [4]byte{}, fmt.Errorf("invalid ipv4 prefix length: %d", prefixLength)
	}
	return [4]byte(mask), nil
}

func ipv6PrefixMask(prefixLength int) ([16]byte, error) {
	prefix := netip.PrefixFrom(netip.IPv6Unspecified(), prefixLength)
	if !prefix.IsValid() {
		return [16]byte{}, fmt.Errorf("invalid ipv6 prefix length: %d", prefixLength)
	}
	mask := net.CIDRMask(prefixLength, 128)
	var output [16]byte
	copy(output[:], mask)
	return output, nil
}

func rawIPv4Sockaddr(address [4]byte) unix.RawSockaddrInet4 {
	return unix.RawSockaddrInet4{
		Len:    unix.SizeofSockaddrInet4,
		Family: unix.AF_INET,
		Addr:   address,
	}
}

func rawIPv6Sockaddr(address [16]byte) unix.RawSockaddrInet6 {
	return unix.RawSockaddrInet6{
		Len:    unix.SizeofSockaddrInet6,
		Family: unix.AF_INET6,
		Addr:   address,
	}
}

// RouteExecutor applies and restores the route operations needed for the tunnel runtime.
type RouteExecutor struct {
	manager NetworkManager
}

// NewRouteExecutor creates a route executor with an explicit native network manager.
func NewRouteExecutor(manager NetworkManager) RouteExecutor {
	return RouteExecutor{manager: manager}
}

// Install applies local relay preservation, interface configuration, and default routes.
func (executor RouteExecutor) Install(parentContext context.Context, plan RoutePlan) error {
	logger.InfoContext(
		parentContext,
		"route install starting",
		"interface_name",
		plan.InterfaceName,
		"install_operations",
		len(plan.InstallOperations),
		"local_relay_preservations",
		len(plan.LocalRelayPreservations),
	)
	ctx, cancel := context.WithTimeout(parentContext, networkMutationTimeout)
	defer cancel()

	preservationOperations, err := executor.localRelayInstallOperations(ctx, plan.LocalRelayPreservations)
	if err != nil {
		logger.ErrorContext(ctx, "route install local relay preservation failed", "err", err)
		return err
	}

	rollbackOperations := make([]NetworkOperation, 0, len(preservationOperations)+len(plan.RemoveOperations))
	for _, operation := range preservationOperations {
		if err := executor.applyOperation(ctx, operation); err != nil {
			logger.ErrorContext(ctx, "route install preservation operation failed", "err", err, "operation", operation.String())
			executor.rollback(ctx, rollbackOperations)
			return fmt.Errorf("apply local relay preservation route operation: %w", err)
		}
		rollbackOperations = append(rollbackOperations, localRelayRemoveOperation(operation))
	}

	for _, operation := range plan.InstallOperations {
		if err := executor.applyOperation(ctx, operation); err != nil {
			logger.ErrorContext(ctx, "route install operation failed", "err", err, "operation", operation.String())
			executor.rollback(ctx, append(reverseOperations(plan.RemoveOperations), rollbackOperations...))
			return fmt.Errorf("apply tunnel route install operation: %w", err)
		}
	}

	logger.InfoContext(ctx, "route install completed", "interface_name", plan.InterfaceName)
	return nil
}

// Remove restores default routes and removes local relay preservation routes.
func (executor RouteExecutor) Remove(parentContext context.Context, plan RoutePlan) error {
	logger.InfoContext(
		parentContext,
		"route removal starting",
		"interface_name",
		plan.InterfaceName,
		"remove_operations",
		len(plan.RemoveOperations),
		"local_relay_preservations",
		len(plan.LocalRelayPreservations),
	)
	ctx, cancel := context.WithTimeout(parentContext, networkMutationTimeout)
	defer cancel()

	var removalError error
	for _, operation := range plan.RemoveOperations {
		if err := executor.applyOperation(ctx, operation); err != nil {
			logger.ErrorContext(ctx, "route removal operation failed", "err", err, "operation", operation.String())
			removalError = errors.Join(removalError, fmt.Errorf("apply tunnel route removal operation: %w", err))
		}
	}

	for _, preservation := range plan.LocalRelayPreservations {
		operation := removeLocalRelayPreservationOperation(preservation)
		if err := executor.applyOperation(ctx, operation); err != nil {
			logger.ErrorContext(ctx, "route removal local relay operation failed", "err", err, "operation", operation.String())
			removalError = errors.Join(removalError, fmt.Errorf("apply local relay route removal operation: %w", err))
		}
	}

	if removalError != nil {
		return removalError
	}
	logger.InfoContext(ctx, "route removal completed", "interface_name", plan.InterfaceName)
	return nil
}

func (executor RouteExecutor) localRelayInstallOperations(
	ctx context.Context,
	preservations []LocalRelayPreservation,
) ([]NetworkOperation, error) {
	operations := make([]NetworkOperation, 0, len(preservations))
	for _, preservation := range preservations {
		interfaceName, err := executor.manager.FindRouteInterface(ctx, preservation)
		if err != nil {
			logger.ErrorContext(ctx, "local relay route interface lookup failed", "err", err)
			return nil, fmt.Errorf("find local relay route interface: %w", err)
		}
		operations = append(operations, addLocalRelayPreservationOperation(preservation, interfaceName))
	}
	return operations, nil
}

func (executor RouteExecutor) applyOperation(ctx context.Context, operation NetworkOperation) error {
	switch operation.Kind {
	case networkOperationIPv4Address:
		return executor.wrapOperationError(ctx, "configure ipv4 address", operation, executor.manager.ConfigureIPv4Address(ctx, operation))
	case networkOperationIPv6Address:
		return executor.wrapOperationError(ctx, "configure ipv6 address", operation, executor.manager.ConfigureIPv6Address(ctx, operation))
	case networkOperationInterfaceMTUAndUp:
		return executor.wrapOperationError(ctx, "configure interface mtu and up", operation, executor.manager.ConfigureInterfaceMTUAndUp(ctx, operation))
	case networkOperationAddIPv4Default, networkOperationAddIPv6Default:
		return executor.wrapOperationError(ctx, "add default route", operation, executor.manager.AddDefaultRoute(ctx, operation))
	case networkOperationDeleteIPv4Default, networkOperationDeleteIPv6Default:
		return executor.wrapOperationError(ctx, "delete default route", operation, executor.manager.DeleteDefaultRoute(ctx, operation))
	case networkOperationAddIPv4RelayHost, networkOperationAddIPv6RelayHost:
		return executor.wrapOperationError(ctx, "add local relay route", operation, executor.manager.AddLocalRelayRoute(ctx, operation))
	case networkOperationDeleteIPv4RelayHost, networkOperationDeleteIPv6RelayHost:
		return executor.wrapOperationError(ctx, "delete local relay route", operation, executor.manager.DeleteLocalRelayRoute(ctx, operation))
	default:
		logger.ErrorContext(ctx, "network operation unsupported", "err", errUnsupportedNetworkOperation, "operation", operation.Kind)
		return fmt.Errorf("%w: %s", errUnsupportedNetworkOperation, operation.Kind)
	}
}

func (executor RouteExecutor) wrapOperationError(
	ctx context.Context,
	operationName string,
	operation NetworkOperation,
	err error,
) error {
	if err == nil {
		return nil
	}
	logger.ErrorContext(ctx, "network operation failed", "err", err, "operation", operation.Kind, "operation_name", operationName)
	return fmt.Errorf("%s %s: %w", operationName, operation.Kind, err)
}

func addLocalRelayPreservationOperation(
	preservation LocalRelayPreservation,
	interfaceName string,
) NetworkOperation {
	if preservation.AddressFamily == RelayAddressFamilyIPv6 {
		return NetworkOperation{
			Kind:           networkOperationAddIPv6RelayHost,
			EndpointHost:   preservation.EndpointHost,
			RelayInterface: interfaceName,
			AddressFamily:  RelayAddressFamilyIPv6,
		}
	}
	return NetworkOperation{
		Kind:           networkOperationAddIPv4RelayHost,
		EndpointHost:   preservation.EndpointHost,
		RelayInterface: interfaceName,
		AddressFamily:  RelayAddressFamilyIPv4,
	}
}

func removeLocalRelayPreservationOperation(preservation LocalRelayPreservation) NetworkOperation {
	if preservation.AddressFamily == RelayAddressFamilyIPv6 {
		return NetworkOperation{
			Kind:          networkOperationDeleteIPv6RelayHost,
			EndpointHost:  preservation.EndpointHost,
			AddressFamily: RelayAddressFamilyIPv6,
		}
	}
	return NetworkOperation{
		Kind:          networkOperationDeleteIPv4RelayHost,
		EndpointHost:  preservation.EndpointHost,
		AddressFamily: RelayAddressFamilyIPv4,
	}
}

func localRelayRemoveOperation(operation NetworkOperation) NetworkOperation {
	if operation.Kind == networkOperationAddIPv6RelayHost {
		return NetworkOperation{
			Kind:          networkOperationDeleteIPv6RelayHost,
			EndpointHost:  operation.EndpointHost,
			AddressFamily: RelayAddressFamilyIPv6,
		}
	}
	if operation.Kind == networkOperationAddIPv4RelayHost {
		return NetworkOperation{
			Kind:          networkOperationDeleteIPv4RelayHost,
			EndpointHost:  operation.EndpointHost,
			AddressFamily: RelayAddressFamilyIPv4,
		}
	}
	return operation
}

func (executor RouteExecutor) rollback(ctx context.Context, operations []NetworkOperation) {
	logger.InfoContext(ctx, "route rollback starting", "operation_count", len(operations))
	for _, operation := range operations {
		if err := executor.applyOperation(ctx, operation); err != nil {
			logger.ErrorContext(ctx, "route rollback operation failed", "err", err, "operation", operation.String())
		}
	}
	logger.InfoContext(ctx, "route rollback completed", "operation_count", len(operations))
}

func reverseOperations(operations []NetworkOperation) []NetworkOperation {
	reversed := make([]NetworkOperation, 0, len(operations))
	for index := len(operations) - 1; index >= 0; index-- {
		reversed = append(reversed, operations[index])
	}
	return reversed
}

package tunnel

import (
	"net"
	"strconv"
	"strings"
)

const (
	defaultIPv4Route = "0.0.0.0/0"
	defaultIPv6Route = "::/0"
)

// RoutePlan describes interface setup and route mutation commands.
type RoutePlan struct {
	InterfaceName   string
	IPv4Routes      []string
	IPv6Routes      []string
	InstallCommands []RouteCommand
	RemoveCommands  []RouteCommand
}

// RouteCommand describes one external route or interface command.
type RouteCommand struct {
	Program   string
	Arguments []string
}

// String renders a route command for dry-run output.
func (command RouteCommand) String() string {
	return command.Program + " " + strings.Join(command.Arguments, " ")
}

// BuildRoutePlan creates the dual-stack route mutation plan.
func BuildRoutePlan(config Config, interfaceName string) RoutePlan {
	interfaceName = resolvedInterfaceName(config, interfaceName)
	installCommands := buildInstallCommands(config, interfaceName)
	removeCommands := buildRemoveCommands(interfaceName)

	plan := RoutePlan{
		InterfaceName:   interfaceName,
		IPv4Routes:      []string{defaultIPv4Route},
		IPv6Routes:      []string{defaultIPv6Route},
		InstallCommands: installCommands,
		RemoveCommands:  removeCommands,
	}
	logger.Info(
		"route plan built",
		"interface_name",
		plan.InterfaceName,
		"install_commands",
		len(plan.InstallCommands),
		"remove_commands",
		len(plan.RemoveCommands),
	)
	return plan
}

func resolvedInterfaceName(config Config, interfaceName string) string {
	if interfaceName == "" {
		logger.Info("route plan using interface hint", "interface_hint", config.InterfaceNameHint)
		return config.InterfaceNameHint + "*"
	}

	logger.Info("route plan using concrete interface", "interface_name", interfaceName)
	return interfaceName
}

func buildInstallCommands(config Config, interfaceName string) []RouteCommand {
	ipv6PrefixLength := strconv.Itoa(config.IPv6PrefixLength)
	mtu := strconv.Itoa(config.MTU)

	return []RouteCommand{
		{
			Program: "ifconfig",
			Arguments: []string{
				interfaceName,
				"inet",
				config.IPv4Address,
				config.IPv4PeerAddress,
				"netmask",
				IPv4Netmask(config.IPv4PrefixLength),
				"mtu",
				mtu,
				"up",
			},
		},
		{
			Program: "ifconfig",
			Arguments: []string{
				interfaceName,
				"inet6",
				config.IPv6Address,
				"prefixlen",
				ipv6PrefixLength,
				"up",
			},
		},
		{
			Program: "route",
			Arguments: []string{
				"-n",
				"add",
				"-inet",
				"default",
				"-interface",
				interfaceName,
			},
		},
		{
			Program: "route",
			Arguments: []string{
				"-n",
				"add",
				"-inet6",
				"default",
				"-interface",
				interfaceName,
			},
		},
	}
}

func buildRemoveCommands(interfaceName string) []RouteCommand {
	return []RouteCommand{
		{
			Program: "route",
			Arguments: []string{
				"-n",
				"delete",
				"-inet",
				"default",
				"-interface",
				interfaceName,
			},
		},
		{
			Program: "route",
			Arguments: []string{
				"-n",
				"delete",
				"-inet6",
				"default",
				"-interface",
				interfaceName,
			},
		},
	}
}

// IPv4Netmask converts an IPv4 prefix length into dotted-quad form.
func IPv4Netmask(prefixLength int) string {
	mask := net.CIDRMask(prefixLength, 32)
	if len(mask) != net.IPv4len {
		logger.Error("invalid IPv4 prefix length", "err", net.InvalidAddrError("invalid IPv4 prefix length"), "prefix_length", prefixLength)
		return ""
	}

	return net.IP(mask).String()
}

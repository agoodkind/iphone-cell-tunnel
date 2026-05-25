# MVP WireGuard Relay Architecture

Cell Tunnel carries Mac IPv4 and IPv6 traffic through a foreground iPhone app so the public network
path uses the iPhone cellular interface.

## Packet Path

```text
Mac application traffic
    |
    v
macOS route table
    |
    v
Mac utun interface
    |
    v
celltunneld
    |
    v
wireguard-go client device
    |
    v
Encrypted WireGuard UDP datagram
    |
    v
TCP relay framer in celltunneld
    |
    v
Apple usbmuxd daemon on the Mac
    |
    v
USB cable
    |
    v
Loopback port on the iPhone
    |
    v
CellTunnelPhone foreground relay
    |
    v
iPhone Network.framework UDP connection bound to cellular
    |
    v
Hosted WireGuard server
    |
    v
Internet
```

Return traffic follows the same path in reverse.

## Components

- `CellTunnelMac` registers the launch daemon, stores local settings, and talks to `celltunneld`
  through generated Swift gRPC bindings over `/var/run/io.goodkind.celltunnel/control.sock`.
- `celltunnelctl` talks to `celltunneld` through the same generated Swift gRPC bindings as
  `CellTunnelMac`.
- `celltunneld` owns the gRPC control service, native DNS-SD discovery, selected relay state,
  `utun`, route mutation, the `wireguard-go` client device, and the local relay TCP framer.
- `CellTunnelPhone` accepts the local relay TCP connection on its own loopback port and forwards
  encrypted WireGuard UDP datagrams to the hosted server through a cellular-bound
  `Network.framework` UDP connection.
- `CellTunnelCore` owns the shared Swift relay frame types, counters, and generated typed control
  IPC models.
- The hosted WireGuard server terminates WireGuard and forwards decrypted IPv4 and IPv6 traffic to
  the internet.

## Mac to iPhone Transport

The Mac reaches the iPhone TCP listener through Apple's USB Multiplex daemon. That daemon ships
with macOS as `/var/run/usbmuxd`. Xcode, Apple Configurator, and libimobiledevice all use the same
daemon.

The Go-side wrapper for usbmuxd lives in `Daemon/internal/usbmuxd/`. It uses
`github.com/danielpaulus/go-ios` for device enumeration and stream dialing. The wrapper exposes
`ListDevices()` and `Dial(deviceID, port)`. The dial returns a plain `net.Conn` so the relay client
treats the usbmuxd transport the same as a raw TCP dial.

The relay endpoint string for this transport is `usbmuxd:<UDID>:<port>`. The Swift CLI parser
recognizes the `usbmuxd:` prefix and stores the value as `host="usbmuxd:<UDID>"` plus
`port=<port>`. Both Swift `socketAddress` and Go `Endpoint.SocketAddress` special-case that prefix
to skip IPv6 bracketing.

`buildRelayClient` in `Daemon/internal/tunnel/relay_client.go` selects the usbmuxd dialer for any
endpoint whose host starts with `usbmuxd:`. All other hosts use the default TCP dialer.
`buildLocalRelayPreservations` in `Daemon/internal/tunnel/route_plan.go` skips local-relay route
preservation entirely for `usbmuxd:` endpoints because no IP route exists for the relay leg.

## Routes

`celltunneld` reads the WireGuard config and installs one host route per `AllowedIPs` entry. With
the smoke config in `/Users/agoodkind/Desktop/wireguard-export/example.com only.conf` that means a
route for `208.67.222.222/32` and a route for `2620:119:35::35/128`. The daemon does not install a
blanket default route.

Routes go in through the BSD routing socket from `Daemon/internal/tunnel/route_executor.go`. The
runtime does not shell out to `route`, `ifconfig`, or `networksetup`.

## Discovery

`celltunneld` performs Bonjour discovery through `DNSServiceBrowse`, `DNSServiceResolve`, and
`DNSServiceGetAddrInfo` from `dns_sd.h`. It enables `kDNSServiceFlagsIncludeP2P` so iPhone-side
services published with `includePeerToPeer = true` are visible over USB-NCM.

The auto-pick heuristic at `Sources/CellTunnelCore/RelayInterfaceSelection.swift` prefers services
whose interface index carries a `169.254.x.x` IPv4 link-local address. Auto-pick is non-deterministic
across reboots and selects services whose transport leg dies after 18 seconds. The canonical relay
endpoint for working traffic is the explicit `usbmuxd:<UDID>:<port>` override.

## Non-Negotiable Data Rules

- The iPhone app treats every WireGuard datagram as opaque bytes.
- The relay protocol carries one encrypted WireGuard UDP datagram per `wireGuardDatagram` frame.
- The relay protocol does not inspect, decrypt, or rewrite inner IPv4 or IPv6 packets.
- Runtime route and interface mutation does not invoke `route`, `ifconfig`, `networksetup`, shells,
  `os/exec`, or `syscall.ForkExec`.
- Secrets never appear in logs, committed source, committed examples, or chat output.

## Runtime Configuration

- `CellTunnelMac` and `celltunnelctl` send `TunnelControlService.StartTunnel` RPCs with the
  WireGuard config path and an optional explicit relay endpoint override.
- If a start request omits the relay endpoint override, `celltunneld` uses the daemon-selected
  discovered relay.
- The WireGuard config file contains the interface private key, interface addresses, hosted server
  peer, allowed IP ranges, and keepalive setting.

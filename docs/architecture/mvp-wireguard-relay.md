# MVP WireGuard Relay Architecture

Cell Tunnel carries Mac IPv4 and IPv6 traffic through a foreground iPhone app so the public network path uses
the iPhone cellular interface.

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
Local Mac-to-iPhone relay
    |
    v
CellTunnelPhone foreground relay
    |
    v
iPhone Network.framework UDP connection with cellular required
    |
    v
Hosted WireGuard server
    |
    v
Internet
```

Return traffic follows the same path in reverse.

## Responsibilities

- `CellTunnelMac` registers the launch daemon, stores local settings, and uses generated Swift gRPC bindings over
  `/var/run/io.goodkind.celltunnel/control.sock` for status, checks, discovery, relay selection, start, and stop.
- `celltunnelctl` uses the same generated Swift gRPC bindings as `CellTunnelMac`.
- `celltunneld` owns the gRPC control service, native DNS-SD discovery, selected relay state, `utun`, route mutation,
  the `wireguard-go` client device, and the local relay connection to the iPhone app.
- `CellTunnelPhone` accepts the local relay connection and forwards encrypted WireGuard UDP datagrams to the hosted
  WireGuard server through a cellular-required `Network.framework` UDP connection.
- `CellTunnelCore` owns the shared Swift relay frame types, counters, and generated typed control IPC models.
- The hosted WireGuard server terminates WireGuard and forwards decrypted IPv4 and IPv6 traffic to the internet.

## Non-Negotiable Data Rules

- The iPhone app treats every WireGuard datagram as opaque bytes.
- The relay protocol carries one encrypted WireGuard UDP datagram per `wireGuardDatagram` frame.
- The relay protocol does not inspect, decrypt, or rewrite inner IPv4 or IPv6 packets.
- Runtime route and interface mutation does not invoke `route`, `ifconfig`, `networksetup`, shells, `os/exec`, or
  `syscall.ForkExec`.
- Secrets never appear in logs, committed source, committed examples, or chat output.

## Runtime Configuration

- `CellTunnelMac` and `celltunnelctl` send `TunnelControlService.StartTunnel` RPCs with the WireGuard config path and
  an optional explicit relay endpoint override.
- If a start request omits the relay endpoint override, `celltunneld` uses the daemon-selected discovered relay.
- `celltunneld` performs discovery through `DNSServiceBrowse`, `DNSServiceResolve`, and `DNSServiceGetAddrInfo` from
  `dns_sd.h`, always enabling `kDNSServiceFlagsIncludeP2P`.
- `celltunneld` prefers IPv6 relay endpoints when both IPv6 and IPv4 are available for the same discovered service.
- The WireGuard config file contains the interface private key, interface addresses, hosted server peer, allowed IP
  ranges, and keepalive setting.

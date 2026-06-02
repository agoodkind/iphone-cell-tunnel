# Cell Tunnel system functionality

A technical reference of what the system does. Functionality only.

## Purpose

A Mac sends its internet traffic through an iPhone's cellular radio without using
iOS Personal Hotspot. The traffic is encrypted end to end with WireGuard, a VPN
protocol. The iPhone app can be closed while this works.

## Data path

Each outbound packet crosses seven hops, and replies retrace the same path:

1. Mac WireGuard wraps each outbound IP packet into an encrypted UDP datagram.
2. The Mac packet-tunnel extension sends the datagram to the Mac agent over
   loopback as plain UDP.
3. The Mac agent bridges the datagram to the iPhone connection over the local
   link.
4. The local link carries the datagram as plain UDP.
5. The iPhone packet-tunnel extension receives the datagram.
6. The iPhone sends the datagram out the cellular radio as plain UDP.
7. The hosted WireGuard server decrypts and forwards to the internet.

## Components

- Mac WireGuard: produces and consumes encrypted UDP datagrams. It runs as a
  crypto engine only and does not decide routes.
- Mac packet-tunnel extension: bridges WireGuard datagrams to and from the agent
  over loopback, and owns route installation on the Mac.
- Mac agent: a background process with no window. It hosts the control listener
  and the relay data listener, and bridges datagrams between the Mac extension
  over loopback and the iPhone over the local link.
- iPhone packet-tunnel extension: dials the agent, bridges the link datagram
  channel to and from the cellular UDP socket to the WireGuard server, chooses
  which path the local link uses, and changes it on its own.
- WireGuard server: a hosted peer that decrypts and forwards to the internet.

The Mac-to-iPhone link is hosted by the agent and dialed by the extensions. A
listener inside a packet-tunnel extension does not receive inbound from the peer
device over the local link, on either platform.

## Control operations

The agent answers a control channel. Each request returns an updated snapshot or
a typed failure. The operations are:

- status: return the current status snapshot.
- check: return the environment report.
- startTunnel(settings): start the tunnel with the given settings.
- stopTunnel: stop the tunnel.
- reset: reset the tunnel state.
- reloadTunnel(settings): apply new settings to the running tunnel in place.
- startRelayDiscovery: begin browsing for relay services on the network.
- stopRelayDiscovery: stop browsing.
- listRelayServices: return the currently discovered relay services.
- selectRelayService(serviceID): choose which discovered relay service to use.

Start and reload settings carry:

- wireGuardConfigPath: filesystem path to the WireGuard configuration.
- relayEndpoint: an optional explicit host and port. When omitted, the agent uses
  its own selected relay.

## Status snapshot

The status snapshot carries:

- running: whether the tunnel is up.
- routeState: installed or not-installed.
- peerState: not-selected, relay-selected, or wireguard-configured.
- ipv4Address: the tunnel interface IPv4 address.
- ipv6Address: the tunnel interface IPv6 address.
- lastError: the most recent error message, or nothing.
- discovery: the relay discovery snapshot, described below.
- activeRelayEndpoint: the host and port of the relay currently in use, or
  nothing.
- macCounters: the traffic counters measured on the Mac side, or nothing.
- phoneCounters: the traffic counters measured on the iPhone side, or nothing.
- cellularPath: the cellular path snapshot, described below.
- connectedPeerName: the name of the connected peer device, or nothing.
- relayState: a short readiness word for the relay, or nothing.

### Traffic counters

Each counters set carries:

- Datagrams from the Mac.
- Datagrams to the Mac.
- Datagrams to the server.
- Datagrams from the server.
- Dropped datagrams.
- Bytes in.
- Bytes out.

The Mac side and the iPhone side each report their own counters.

### Cellular path snapshot

- isSatisfied: whether the cellular path is currently usable.
- supportsIPv4: whether the path carries IPv4.
- supportsIPv6: whether the path carries IPv6.
- interfaceName: the cellular interface name, or nothing.
- interfaceIndex: the cellular interface number, or nothing.

## Relay discovery

The agent finds the iPhone relay on the local network with Bonjour service
discovery. The discovery snapshot carries:

- phase: browsing, ready, stopped, or failed.
- services: the list of discovered relay services.
- selectedServiceID: the chosen service, or nothing.
- selectedEndpoint: the chosen host and port, or nothing.
- lastError: the most recent discovery error, or nothing.

Each discovered service carries an id, a service name, a service type, a domain,
an interface number, a host name, a list of endpoints, a preferred endpoint, and
whether it is selected. Each endpoint carries a host, a port, and an address
family of IPv4, IPv6, or unspecified.

A relay endpoint may also be addressed through a device-tunnel scheme, prefixed
`usbmuxd:` or `tunneld:`, in which case the host carries a device identifier.

## Environment report

The check operation returns an environment report, a list of named checks. Each
check carries a name and a value. The iPhone returns no checks. The agent
returns its own set.

## Error codes

A failed control request returns one of these codes with a message: internal,
discoveryUnavailable, invalidRelayEndpoint, missingWireGuardConfigPath,
relaySelectionRequired, relayServiceNotFound, runtimeStartFailure, unspecified.

## Path selection and failover

- The iPhone keeps a connection to the agent open over every reachable path at
  once and carries traffic on one of them, so a path loss moves traffic to an
  already-open path without a reconnect.
- One link is one UDP connection over one interface. The agent advertises the
  relay on every path. The iPhone browses once, reads the interfaces the agent is
  reachable on, and dials one link per interface pinned to it. The USB link, a
  USB-C Ethernet adapter, Wi-Fi LAN, and AWDL each become their own link.
- Both ends pick the carrying link the same way from a preference order: USB over
  Wi-Fi LAN over AWDL. An explicit interface override takes precedence when set.
- A link closes when its connection errors or a send on it fails. When the
  carrying link's send fails, traffic moves to the next open link. A replugged
  interface is rediscovered and dialed again. Failover is driven by traffic, not
  a timer.

## Routing

- The destinations the Mac tunnel captures are a program-owned scoped list, not
  the WireGuard config's address ranges. The Mac extension installs the scoped
  list while the iPhone link is up and withdraws it to none while the link is
  down.
- WireGuard's own wide address ranges select which peer encrypts a packet and do
  not decide which traffic the tunnel captures. The captured routes stay scoped
  and never widen to all traffic.
- The Mac tunnel comes up connected immediately and stays connected with no
  captured routes until the iPhone relay link is up.

## Live configuration changes

A change to the running tunnel falls into one of three tiers:

- Live: takes effect with no profile save and no session restart. Covers the
  WireGuard keys, peer endpoint, address ranges, interface addresses, MTU,
  keepalive, the captured route set, and DNS. The agent reads an edited config
  file and forwards it, and the extension reloads it in place.
- Profile save: covers the cold-start seed the system uses when it launches the
  extension on its own, the on-demand rules, and the server address.
- Reinstall: covers app code, entitlements, and bundle identifiers.

## Cellular egress

- The cellular egress is pinned to the cellular interface. iOS Personal Hotspot
  is never used.
- The iPhone limits how many datagrams sit in the cellular socket at once and
  sizes that limit from the time each datagram waits for the socket to accept it,
  so the local send buffer stays short and upload latency under load stays low.

## Throughput measurement

The upload and download rates are computed from the change in byte counts between
two status readings. They read above zero only while traffic is flowing.

## Background operation

- The iPhone relay runs inside a packet-tunnel extension, the iOS mechanism that
  keeps a custom process and its sockets alive in the background over cellular.
  An on-demand connect rule makes it always-on.
- The iPhone provider captures no routes, so the iPhone's own traffic and the
  relay's cellular socket are not pulled into the tunnel.
- The agent exits when idle to free resources, but holds that idle timer for the
  life of the relay bridge so it does not strand the iPhone mid-relay.

## Transports

- Control channel: a libxpc session to the agent's mach service. Each request
  crosses as JSON in one data field of an xpc dictionary, and the reply carries
  JSON. One client serves every caller.
- iPhone status channel: the packet-tunnel provider message channel, used to read
  status from and send control to the iPhone extension.
- Data plane: plain UDP over the local link, and loopback UDP between the Mac
  extension and the agent. The usbmux loopback channel is not used on the data
  plane.

## Source of truth in the code

- Control operations and wire types: `Sources/CellTunnelCore/AgentControlRequest.swift`
- Status, counters, discovery, settings, error codes: `Sources/CellTunnelCore/TunnelDaemonStatusSnapshot.swift`, `Sources/CellTunnelCore/TunnelCounters.swift`
- Mac agent: `Apps/macOS/Agent/`
- Mac tunnel provider and routing: `Apps/macOS/TunnelProvider/`
- iPhone tunnel provider: `Apps/PhoneTunnelProvider/`
- Architecture overview: `docs/architecture.md`

# Cell Tunnel architecture

## Goal

A Mac sends its internet traffic through an iPhone's cellular radio, without iOS Personal Hotspot.

The iPhone app is closed while this works.

## Data path

The path has seven hops. Each hop names its transport.

1. Mac WireGuard wraps each outbound IP packet into an encrypted UDP datagram.
2. Mac packet-tunnel extension sends the datagram to the Mac agent over loopback as plain UDP.
3. Mac agent bridges the datagram to the iPhone connection over the local link.
4. Local link carries the datagram as plain UDP (`NWConnection`).
5. iPhone packet-tunnel extension receives the datagram.
6. iPhone sends the datagram out the cellular radio (`pdp_ip0`) as plain UDP.
7. Hosted WireGuard server decrypts and forwards to the internet, then replies retrace the path.

Terms:

- "Packet-tunnel extension" = an `NEPacketTunnelProvider`, an app extension iOS keeps running in the background.
- "Mac agent" = the user-land background process that hosts the link listeners and bridges the relay data plane between the Mac extension and the iPhone.
- "Local link" = the Mac-to-iPhone interface, typically CDC-NCM Ethernet-over-USB with an IPv6 link-local address. The Network framework keeps the path transport-agnostic.
- "Control plane" = the one message that gives the iPhone the WireGuard server address.
- "Data plane" = the per-packet relay of WireGuard UDP datagrams in both directions.

## Component responsibilities

Each component handles only its own leg and knows nothing of the others.

- Mac WireGuard: produces and consumes encrypted UDP datagrams. Knows nothing about the link.
- Mac packet-tunnel extension: bridges WireGuard datagrams to and from the agent over loopback.
- Mac agent: hosts the relay data listener, bridging datagrams between the Mac extension over loopback and the iPhone over the local link.
- iPhone packet-tunnel extension: dials the agent, then bridges the link datagram channel to and from the cellular UDP socket to the WireGuard server.

WireGuard is a transport tool, not a participant. Its handshake carries no project logic. The only WireGuard timing the project sets is `PersistentKeepalive = 25` from the config.

## Hard constraints

- The data plane uses plain UDP over the local link.
- usbmux (the iproxy/libusbmuxd loopback channel) is banned from the data plane. It caps near 3 mbps.
- Backgrounding is the success bar. There is no foreground-only data path.
- Routes stay scoped to the config's `AllowedIPs`. Never widened to all traffic (`0.0.0.0/0`, `::/0`).
- iOS Personal Hotspot is never used. The cellular egress is pinned with `requiredInterfaceType = .cellular`.
- The Mac-to-iPhone link is hosted by a normal process and dialed by the extensions. A listener inside a packet-tunnel extension does not receive inbound from the peer device over the local link, on either platform. The Mac agent hosts the control listener and the relay data listener. The iPhone extension dials both. The Mac tunnel extension dials the agent over loopback, and the agent bridges relay datagrams between the loopback side and the iPhone side.

## Why an iOS packet-tunnel extension

The iPhone relay runs inside an `NEPacketTunnelProvider`, the stock iOS mechanism that keeps a custom process and its sockets alive in the background over carrier cellular. An `NEOnDemandRuleConnect` rule makes it always-on. The provider captures no routes, so the iPhone's own traffic and the relay's cellular socket are not pulled into the tunnel.

## Source of truth

| Topic | Source of truth |
|---|---|
| Runtime behavior | The Swift code under `Apps/`, `Sources/`, `Tools/`. |
| Operational and diagnostic commands | `Tools/CellTunnelDev/`, run via `swift Tools/cell-tunnel-dev.swift <command>`. |
| Build, lint, test, install targets | `make help` (generated from the `Makefile`). |
| Identifiers, ports, signing | `Config/Constants.xcconfig` and `Config/local.xcconfig`. |
| Task and ticket state | Tack workspace `main`, project `OSS`, epic `OSS-7`. |
| Component map and house rules | `AGENTS.md`. |

# Cell Tunnel architecture

## Goal

A Mac sends its internet traffic through an iPhone's cellular radio, without iOS Personal Hotspot.

The iPhone app is closed while this works.

## Data path

The path has six hops. Each hop names its transport.

1. Mac WireGuard wraps each outbound IP packet into an encrypted UDP datagram.
2. Mac packet-tunnel extension sends the datagram over the USB link.
3. USB link carries the datagram as plain UDP (`NWConnection`/`NWListener`).
4. iPhone packet-tunnel extension receives the datagram.
5. iPhone sends the datagram out the cellular radio (`pdp_ip0`) as plain UDP.
6. Hosted WireGuard server decrypts and forwards to the internet, then replies retrace the path.

Terms:

- "Packet-tunnel extension" = an `NEPacketTunnelProvider`, an app extension iOS keeps running in the background.
- "USB link" = the Mac-to-iPhone CDC-NCM Ethernet-over-USB interface. On the Mac it is `en11` with an IPv6 link-local address.
- "Control plane" = the one message that gives the iPhone the WireGuard server address.
- "Data plane" = the per-packet relay of WireGuard UDP datagrams in both directions.

## Component responsibilities

Each component handles only its own leg and knows nothing of the others.

- Mac WireGuard: produces and consumes encrypted UDP datagrams. Knows nothing about USB.
- Mac packet-tunnel extension: bridges WireGuard datagrams to and from the USB datagram pipe.
- USB pipe: one bidirectional UDP datagram channel over the USB link.
- iPhone packet-tunnel extension: bridges the USB datagram pipe to and from the cellular UDP socket to the WireGuard server.

WireGuard is a transport tool, not a participant. Its handshake carries no project logic. The only WireGuard timing the project sets is `PersistentKeepalive = 25` from the config.

## Hard constraints

- The data plane uses plain UDP over the USB link.
- usbmux (the iproxy/libusbmuxd loopback channel) is banned from the data plane. It caps near 3 mbps.
- Backgrounding is the success bar. There is no foreground-only data path.
- Routes stay scoped to the config's `AllowedIPs`. Never widened to all traffic (`0.0.0.0/0`, `::/0`).
- iOS Personal Hotspot is never used. The cellular egress is pinned with `requiredInterfaceType = .cellular`.

## Why an iOS packet-tunnel extension

The iPhone relay runs inside an `NEPacketTunnelProvider` because it is the stock iOS mechanism that keeps a custom process and its sockets alive in the background over carrier cellular. An on-demand connect rule (`NEOnDemandRuleConnect`) makes it effectively always-on.

The provider hosts the relay's own sockets. It is configured with no captured routes, so the iPhone's own traffic and the relay's cellular socket are not pulled into the tunnel.

The rejected alternatives:

- `NEAppPushProvider` (Local Push Connectivity) activates only on a matched Wi-Fi SSID or a private LTE network. There is no trigger for public carrier cellular.
- `NEAppProxyProvider` and `NETransparentProxyProvider` are per-app flow proxies. They do not accept an inbound listener and forward raw UDP.
- Plain `UIBackgroundModes` does not keep an arbitrary listener and outbound socket alive. The app is suspended.

The accepted trade-offs: iOS shows the VPN indicator while the provider runs, and the active VPN configuration bypasses iCloud Private Relay.

## Source of truth

| Topic | Source of truth |
|---|---|
| Runtime behavior | The Swift code under `Apps/`, `Sources/`, `Tools/`. |
| Operational and diagnostic commands | `Tools/CellTunnelDev/`, run via `swift Tools/cell-tunnel-dev.swift <command>`. |
| Build, lint, test, install targets | `make help` (generated from the `Makefile`). |
| Identifiers, ports, signing | `Config/Constants.xcconfig` and `Config/local.xcconfig`. |
| Task and ticket state | Tack workspace `main`, project `OSS`, epic `OSS-7`. |
| Active inbound-path investigation | `docs/ne-inbound-investigation.md`. |
| Background-extension rationale | `docs/plans/ios-background-network-extension.md`. |
| Component map and house rules | `AGENTS.md`. |

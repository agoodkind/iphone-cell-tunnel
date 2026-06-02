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
- "Local link" = the Mac-to-iPhone interface, typically CDC-NCM Ethernet-over-USB with an IPv6 link-local address. The Network framework keeps the path transport-agnostic, and the iPhone auto-selects the fastest reachable path. See "Path selection".
- "Control plane" = the one message that gives the iPhone the WireGuard server address.
- "Data plane" = the per-packet relay of WireGuard UDP datagrams in both directions.

## Component responsibilities

Each component handles only its own leg and knows nothing of the others.

- Mac WireGuard: produces and consumes encrypted UDP datagrams. Knows nothing about the link.
- Mac packet-tunnel extension: bridges WireGuard datagrams to and from the agent over loopback.
- Mac agent: hosts the relay data listener, bridging datagrams between the Mac extension over loopback and the iPhone over the local link.
- iPhone packet-tunnel extension: dials the agent, then bridges the link datagram channel to and from the cellular UDP socket to the WireGuard server. It also chooses which path the local link uses and changes it on its own. See "Path selection". It limits how many datagrams sit in the cellular socket at once and sizes that limit from the time each datagram waits for the socket to accept it, so the local send buffer stays short and upload latency under load stays low.

WireGuard is a transport tool, not a participant. Its handshake carries no project logic. The only WireGuard timing the project sets is `PersistentKeepalive = 25` from the config.

## User interface

One app target, `CellTunnelPhone`, builds two products from the same SwiftUI screens. The iPhone product drives the iPhone relay and shows the status screen and the developer console. The Mac product is built through Mac Catalyst and is a read-only front-end to the agent: it shows the same screens filled from the agent's status snapshot and owns no tunnel.

The views bind to one observable controller, `RelayController`, which holds a `RelayControlBackend` and never branches on platform. Two backends sit behind it. `PhoneRelayBackend` (iPhone) owns the tunnel manager, the on-demand rule, the device-name publish, and the status poll over the provider message channel. `AgentRelayBackend` (Mac) reads the agent's status and maps it onto the same reading the views render.

The Mac reaches the agent the same way the command-line tool does: it opens an `XPCSession` to the agent's mach service `AGENT_MACH_SERVICE_NAME`, served by `AgentSessionListener` over the libxpc protocol. One shared client, `AgentClient`, carries both. A Mac Catalyst app cannot open an `NSXPCConnection` to a mach service, so the libxpc session API is the one transport every control client uses. Each request crosses as `AgentControlEnvelope` JSON in one data field of an xpc dictionary, and the reply carries `AgentControlResponse` JSON.

## Path selection

The iPhone keeps a connection to the agent open over every reachable path at once and carries traffic on one of them, so a path loss moves traffic to an already-open path without a reconnect.

- One link is one UDP connection to the agent over one interface. The agent advertises the relay service on every path, the iPhone runs one Bonjour browse and reads the interfaces the agent is reachable on, and the iPhone dials one link per interface pinned to it (`requiredInterface`), so the USB CDC-NCM link, a USB-C Ethernet adapter, Wi-Fi LAN, and AWDL each become their own link. Each link is primed with one empty datagram so the agent adopts it; the relay forwards only non-empty datagrams, so the prime never reaches WireGuard.
- One link carries traffic. Both ends pick it the same way from a preference order, USB over Wi-Fi LAN over AWDL, held as scores in `RelayLinkScorer`; an explicit interface override takes precedence when set. The choice is a pure function (`RelayLinkPolicy.chooseCarrying`) recomputed only when a link opens or closes, and the per-datagram path reads it as one cached pointer, so the decision never runs on the packet path.
- A link closes only when its connection errors or a send on it fails. A send failure (no route to host when an interface goes away) is the reliable signal a UDP path is gone, since the connection state may not change. When the carrying link's send fails it is dropped and traffic moves to the next open link; a replugged interface is rediscovered and dialed again. Failover is driven by traffic, not a timer, so it is immediate under load and happens on the next packet when nearly idle.
- The override is the seam a UI or a later selection algorithm uses to set the carrying link without touching discovery or the packet path.

## Configuration and routes

The program owns the captured route set and the WireGuard configuration as values it holds, applied to the running tunnel through a single boundary.

- The destinations the Mac tunnel captures are a program-owned scoped list, not the WireGuard config's `AllowedIPs`. The single relay peer's cryptokey `AllowedIPs` span `0.0.0.0/0` and `::/0` so WireGuard encrypts every captured packet to the one peer, while the OS routes the tunnel installs come from the program list. `RouteGate` (`Apps/macOS/TunnelProvider/Runtime/RouteGate.swift`) is the sole authority over `includedRoutes`: it installs the program list while the iPhone link is up, strips captured routes to none while it is down, and discards the wide routes WireGuardKit derives from the broad cryptokey `AllowedIPs`. The captured routes therefore stay scoped and never widen to `0.0.0.0/0` or `::/0`.
- A change to the running tunnel falls into one of three tiers. The live tier takes effect with no VPN profile save and no session restart, covering the WireGuard keys, peer endpoint, cryptokey `AllowedIPs`, interface addresses, MTU, keepalive, the captured route set, and DNS; the running tunnel applies these through `WireGuardAdapter.update(tunnelConfiguration:)`, which reconfigures the backend and reapplies settings while preserving the relay bind, followed by a `RouteGate` reapply. The profile-save tier calls `saveToPreferences` with no app reinstall, covering the cold-start seed the system uses when it launches the extension on its own, the on-demand rules, and the server address. The reinstall tier covers app code, entitlements, and bundle identifiers.
- The live tier rides the provider control channel the agent already uses (`session.sendProviderMessage` to the extension's `handleAppMessage`). The agent reads an edited config file and forwards it; the extension reloads it in place. The `relay-reload` command (`Tools/CellTunnelDev`) drives this. The first VPN profile creation and its one-time system approval are the only setup step a configuration change cannot avoid.

## Hard constraints

- The data plane uses plain UDP over the local link.
- usbmux (the iproxy/libusbmuxd loopback channel) is banned from the data plane. It caps near 3 mbps.
- Backgrounding is the success bar. There is no foreground-only data path.
- The captured routes (`includedRoutes`) stay scoped to the program's route list and never widen to all traffic (`0.0.0.0/0`, `::/0`). Those wide values appear only in the relay peer's cryptokey `AllowedIPs`, which select which peer encrypts a packet and do not decide which traffic the tunnel captures.
- The Mac tunnel comes up connected immediately and stays connected with no captured routes until the iPhone relay link is up. The Mac extension owns route installation: WireGuard's adapter applies its settings through the extension's `setTunnelNetworkSettings`, which `RouteGate` intercepts to install the program's scoped route list when the agent signals the iPhone link is up and to withdraw it when the link drops. WireGuard runs as a dumb crypto engine and never decides routes.
- iOS Personal Hotspot is never used. The cellular egress is pinned with `requiredInterfaceType = .cellular`.
- The Mac-to-iPhone link is hosted by a normal process and dialed by the extensions. A listener inside a packet-tunnel extension does not receive inbound from the peer device over the local link, on either platform. The Mac agent hosts the control listener and the relay data listener. The iPhone extension dials both. The Mac tunnel extension dials the agent over loopback, and the agent bridges relay datagrams between the loopback side and the iPhone side.
- The agent does not idle-exit while it hosts an active relay. The agent exits when it is idle to free resources, but it holds that idle timer for the life of the relay bridge, because exiting mid-relay would kill the in-memory bridge and strand the iPhone, and the iPhone's data link is UDP and does not surface that drop on its own.

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

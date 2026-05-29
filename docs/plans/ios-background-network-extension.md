# Plan: run the iPhone relay in the background with a NetworkExtension

## What this gives us

Today the iPhone relay only runs while its app is in the foreground. When the app
goes to the background the system suspends it and the relay stops, so the Mac
loses its path out through cellular. The goal of this plan is to keep the relay
forwarding while the app is backgrounded or the screen is locked, by moving the
relay's network work into a NetworkExtension that the system keeps alive.

## Chosen approach: an iOS packet-tunnel provider used as a keep-alive host

Use `NEPacketTunnelProvider` on iOS. It is the only stock mechanism that keeps a
custom process and its sockets alive in the background over ordinary carrier
cellular, and it can be made effectively always-on with on-demand connect rules.

The provider runs as an app extension. We use it as a long-lived host for the
relay's own sockets (the Mac-facing `NWListener` and the cellular `NWConnection`),
not to capture the iPhone's own traffic. The tunnel is configured with minimal or
no routes so the phone's traffic is not pulled through it.

The accepted trade-off is that iOS shows the VPN indicator while the provider runs
and the active VPN configuration bypasses iCloud Private Relay. That appears to be
unavoidable for true background socket persistence on stock iOS over cellular.

### Why not the alternatives

- `NEAppPushProvider` (Local Push Connectivity) is the only non-VPN long-lived
  option, but it only activates on a matched Wi-Fi SSID or a private LTE network.
  There is no trigger for the public carrier cellular network the relay depends
  on, and its entitlement requires a separate approval request to Apple. It does
  not fit.
- `NEAppProxyProvider` and `NETransparentProxyProvider` are per-app flow proxies
  (and the transparent proxy is macOS only). They intercept this device's app
  flows; they do not accept an inbound listener from the Mac and forward raw UDP.
- Plain `UIBackgroundModes` does not grant a normal app the right to keep an
  arbitrary listener and outbound socket alive; the app still gets suspended.

## What moves where

Move the entire data plane into the new extension, because that is what must
survive backgrounding:

- `PhoneRelayForwarder` and `PhoneRelayForwarder+Cellular` (the serial-queue data
  plane: the Mac-facing `NWListener` and accepted connection, the cellular
  `NWConnection`, the state machine, the pending buffer, and the metrics).
- `PhoneControlListener` (the control channel listener and the status push loop).
- The cellular `NWPathMonitor` and the `requiredInterfaceType = .cellular` egress
  binding.
- The Bonjour advertisement for `_cellrelay._udp` and `_cellrelaycontrol._tcp`,
  which means the extension needs its own `NSBonjourServices` and
  `NSLocalNetworkUsageDescription`.

Keep in the host app:

- The `@Observable` UI state and the status screen (`PhoneRelayController`,
  `PhoneContentView`).
- The code that configures and starts the provider through
  `NETunnelProviderManager`, replacing today's in-process scene-phase start/stop.
- A path for live counters and status from the extension back to the app, using
  `NETunnelProviderSession.sendProviderMessage` plus the shared app group. This
  mirrors the macOS provider's existing `handleAppMessage` pattern.

The macOS side already follows this app-plus-extension split, so it is the
reference for the iOS version.

## Entitlements and Info.plist

Applied to both the iOS app target and a new iOS app-extension target:

- `com.apple.developer.networking.networkextension` set to `packet-tunnel-provider`.
  This is a standard App ID capability and does not need a special Apple request.
- `com.apple.security.application-groups` set to the existing
  `group.io.goodkind.CellTunnel`, so the extension and the app can share status.

On the new extension target's `Info.plist`:

- `NSExtension` with `NSExtensionPointIdentifier` =
  `com.apple.networkextension.packet-tunnel` and `NSExtensionPrincipalClass` set
  to the `NEPacketTunnelProvider` subclass.
- `NSLocalNetworkUsageDescription` and `NSBonjourServices` for `_cellrelay._udp`
  and `_cellrelaycontrol._tcp`.

Provisioning: both Network Extension entitlements require a paid Apple Developer
Program membership and matching provisioning profiles for the app and the
extension. A free personal Apple ID cannot sign these, so a sideloaded free build
will not work for this feature.

## Always-on lifecycle

Configure the tunnel with on-demand connect rules so the system re-establishes it
and keeps the extension (and its sockets) alive in the background. The host app
loads or creates the `NETunnelProviderManager`, sets the on-demand rules and the
provider configuration, saves, and starts the session. The provider's
`startTunnel` brings up the relay's listener and cellular connection; `stopTunnel`
tears them down.

## Risks to verify on device before committing

1. It is not documented that an inbound local-network `NWListener` may keep
   accepting the Mac's connections indefinitely inside a packet-tunnel provider.
   This is the single biggest unknown. Verify on device that the Mac can connect
   to the extension's listener and that the connection survives backgrounding.
2. The cellular-bound outbound `NWConnection` may be captured by the provider's
   own tunnel routes and loop. Configure route exclusion so the relay's socket
   egresses on the physical cellular interface (`pdp_ip0`), and verify it.
3. The VPN indicator shows while running and iCloud Private Relay is bypassed.
   Confirm this is acceptable.
4. NetworkExtension entitlements need a paid developer account and provisioning
   for both targets.
5. The system enforces a memory ceiling on the extension and relaunches it if it
   is killed for memory. The relay's buffering is bounded (the pending queue caps
   at 64 datagrams and the forwarder holds at most one Mac connection and one
   cellular connection), so steady-state memory should be small, but instrument it.

## Suggested order of work

1. Add the iOS app-extension target in `Project.swift` with the entitlements and
   `Info.plist` above, and a minimal `NEPacketTunnelProvider` subclass that does
   nothing but start and log. Confirm it builds, installs, and the host app can
   start and stop the session on device.
2. Verify the two hard unknowns above in that minimal provider: an inbound
   `NWListener` that the Mac can reach and that survives backgrounding, and a
   `.cellular` outbound `NWConnection` that egresses on `pdp_ip0` without being
   captured by the tunnel.
3. Move `PhoneRelayForwarder`, `PhoneRelayForwarder+Cellular`, and
   `PhoneControlListener` into the extension. Wire the host app to start the
   provider and to pull status over `sendProviderMessage` and the app group.
4. Add on-demand connect rules for always-on behavior, and surface the provider
   state in the app's status screen and the developer console.

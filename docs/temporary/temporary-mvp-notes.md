# Cell Tunnel context for the next agent

The single durable handoff. Read this first.

## What the project does

A Mac uses the internet through an iPhone's cellular signal instead of through Wi-Fi. The Mac encrypts each outbound IP packet with WireGuard, ships the encrypted UDP datagram over USB-C or AWDL to an iPhone app, and the iPhone forwards each datagram out the cellular radio to a hosted WireGuard server. The server unwraps and forwards each packet to the real internet. Replies retrace the same path.

The use case is education and research. Personal Hotspot is explicitly off the table. The cellular cap of around 300 Mbps is the throughput goal. The Mac-to-iPhone UDP transport benchmarked at 925 Mbps over USB-C; cellular is the bottleneck.

## Architecture

Three Mac processes plus one iPhone app plus the hosted WireGuard server.

| Process | Location | Privilege | Lifecycle |
|---|---|---|---|
| `celltunnelctl` (CLI) | `Tools/CellTunnelCtl/main.swift` | user | per-command |
| `CellTunnelAgent` (user-space agent) | `Apps/macOS/Agent/main.swift` | user | spawned on demand by CLI |
| `CellTunnelTunnelProvider` (NE extension) | `Apps/macOS/TunnelProvider/PacketTunnelProvider.swift` | `_networkd` via NE entitlement | OS-managed while tunnel is up |
| `CellTunnelPhone` (iPhone app) | `Apps/iOS/**` | user | foreground while testing |

The CLI is the first-class user surface. The GUI is removed from source; reintroduce later as another XPC client of the agent. The CLI talks to the agent over an anonymous XPC endpoint at `/tmp/io.goodkind.celltunnel-agent.sock`. The agent owns the `NETunnelProviderManager` configuration, observes `NEVPNStatusDidChange`, and forwards control messages to the extension via `NETunnelProviderSession.sendProviderMessage`. The extension owns the data path.

Data flow:

```
Mac apps -> kernel routes -> framework utun (NE-managed)
  -> packetFlow.readPackets -> WireGuardAdapter -> wireguard-go reads, encrypts
    -> custom conn.Bind.Send -> cgo callback -> WireGuardRelayBind
      -> RelayTransport -> iPhone -> cellular -> WG server
WG server -> cellular -> iPhone -> RelayTransport
  -> WireGuardRelayBind.inject(endpoint, data) -> wgRelayBindInjectReceive
    -> wireguard-go reads, decrypts -> WireGuardAdapter
      -> packetFlow.writePackets -> framework utun
        -> kernel IP stack -> original Mac app
```

## Mac-to-iPhone transport options

The Network framework primitives in the code path (`NWBrowser`, `NWListener`, `NWConnection`, all with `includePeerToPeer = true`) make the discovery and data path transport-agnostic. Three transports work without code changes:

| Transport | Requires | Throughput | Notes |
|---|---|---|---|
| USB-C (CDC-NCM) | physical cable | ~925 Mbps | most reliable; the default dev path |
| Shared WiFi LAN | both devices on same network | LAN-rate | works through Bonjour mDNS |
| AWDL peer-to-peer | both devices' WiFi radio on, Local Network permission granted | 100-400 Mbps | works without a shared network; same tech as AirDrop |

iPhone-to-server is always cellular. `Apps/iOS/Services/WireGuardDatagramRelaySession.swift` pins `requiredInterfaceType = .cellular`.

## Repos

| Repo | Branch | Purpose |
|---|---|---|
| `/Users/agoodkind/Sites/iphone-cell-tunnel` | `main` | the cell-tunnel project |
| `/Users/agoodkind/Sites/wireguard-apple` | `master` (tracks `agoodkind/wireguard-apple` master) | WireGuard apple fork with custom `conn.Bind` for routing encrypted UDP through Swift transport |

The cell-tunnel project pins the fork via `Tuist/Package.swift`:

```swift
.package(url: "https://github.com/agoodkind/wireguard-apple.git", branch: "master")
```

## WireGuard fork: custom conn.Bind exports

`Sources/WireGuardKitGo/wireguard.h`:

```c
typedef void (*wg_relay_send_callback_t)(void *context,
                                         const uint8_t *endpoint,
                                         size_t endpoint_len,
                                         const uint8_t *data,
                                         size_t data_len);
extern int32_t wgTurnOnWithRelayBind(const char *settings,
                                     int32_t tun_fd,
                                     wg_relay_send_callback_t send_cb,
                                     void *send_ctx);
extern void wgRelayBindInjectReceive(int32_t handle,
                                     const char *endpoint,
                                     size_t endpoint_len,
                                     const uint8_t *data,
                                     size_t data_len);
extern void wgRelayBindUnregister(int32_t handle);
```

`Sources/WireGuardKit/WireGuardAdapter.swift`:

```swift
public protocol WireGuardRelayBindBridge { /* see fork for exact shape */ }
extension WireGuardAdapter {
    public func start(tunnelConfiguration: TunnelConfiguration,
                      relayBind: WireGuardRelayBindBridge,
                      completionHandler: @escaping (WireGuardAdapterError?) -> Void)
}
```

Vendored wireguard-go is at master tip with batched `Send(buffs [][]byte, ep)` and slice-based `ReceiveFunc`. Tests pass on both Go and Swift sides.

## Targets in Project.swift

- `CellTunnelCore` (.framework, iOS + macOS)
- `CellTunnelLog` (.framework, iOS + macOS)
- `CellTunnelPhone` (.app, iOS, automatic signing)
- `CellTunnelAgent` (.commandLineTool, macOS, `Apple Development` automatic signing)
- `CellTunnelTunnelProvider` (.appExtension, macOS, `Apple Development` automatic signing, links `WireGuardKit`)

Both Mac targets carry `com.apple.developer.networking.networkextension = [packet-tunnel-provider]` and `com.apple.security.application-groups = [group.io.goodkind.CellTunnel]`. The Apple Developer account is configured in Xcode > Settings > Apple Accounts, and the development Mac is registered under Devices at developer.apple.com. The agent and tunnel-provider bundle IDs and the App Group are provisioned, and profiles auto-create via `-allowProvisioningUpdates`.

The signing team comes from `TUIST_DEVELOPMENT_TEAM` or `DEVELOPMENT_TEAM`, with the default in `Tools/CellTunnelDev/Support.swift`. On an `Apple Development` certificate the value in the CN parentheses is a Team Member ID, not the Team ID; the real Team ID is the certificate `OU` field and matches the `TeamIdentifier` on the signed `.appex`. An `Apple Distribution` certificate prints the Team ID directly in its CN. Both certificates for the account resolve to the same single team, so a differing CN parenthetical is not a team mismatch.

## Build, install, CLI surface

| Command | Result |
|---|---|
| `make build TARGET=daemon CONFIG=Debug` | builds `celltunnelctl` only |
| `make build TARGET=mac CONFIG=Debug` | builds `CellTunnelAgent` + `CellTunnelTunnelProvider.appex` + runs full lint pipeline |
| `make build TARGET=iphone-device CONFIG=Debug` | builds and signs the iPhone app |
| `make build TARGET=iphone-simulator CONFIG=Debug` | builds the iPhone app for the simulator |
| `make iphone-install CONFIG=Debug` | installs the iPhone app on the connected device |
| `make install-helper CONFIG=Debug` | installs the agent and extension to `/Applications/CellTunnel/` |
| `make daemon-reload` | rebuilds + swaps binary + kickstarts |
| `make smoke` | prints the post-install celltunnelctl sequence (graduate to a subcommand later) |
| `make logs` | prints the log-tail hints (graduate to a subcommand later) |

`make build TARGET=<x>` runs lint and audit before compile. Gates: `swiftlint`, `swift-format`, `lint-complexity` (SwiftLint metrics), `lint-deadcode` (Periphery), `swiftcheck-extra` (custom SwiftSyntax analyzers), `log-audit` (boundary and catch logging rules). Bare `make build` errors; the TARGET argument is required.

`SWIFT_MK_SKIP_FETCH=1` env var skips re-fetching the WireGuard fork on incremental builds.

## Module layout

`Apps/macOS/TunnelProvider/Runtime/`:

- `RelayTransport.swift`: NWConnection UDP to the iPhone over USB or AWDL.
- `ControlChannel.swift`: typed TCP control channel to the iPhone via NWProtocolFramer; carries the WireGuard server endpoint and periodic status pushes.
- `DiscoveryManager.swift`: NWBrowser for `_cellrelay._udp` with peer-to-peer enabled.
- `DiscoveryServiceWaiter.swift`: continuation-plus-timeout helper for the first discovered service.
- `WireGuardRuntime.swift`: actor wrapping `WireGuardAdapter.start(tunnelConfiguration:relayBind:completionHandler:)`.
- `WireGuardConfigParser.swift`: parses a WireGuard `.conf` text.
- `WireGuardTunnelConfigBuilder.swift`: converts the parsed config into WireGuardKit's `TunnelConfiguration`.
- `WireGuardRelayBind.swift`: implements `WireGuardRelayBindBridge`; sends outbound datagrams to `RelayTransport`; injects inbound datagrams via `wgRelayBindInjectReceive`.
- `AddressPrefix.swift`: IP prefix value type.

`Apps/macOS/TunnelProvider/`:

- `PacketTunnelProvider.swift`: `NEPacketTunnelProvider` subclass; owns `startTunnel`, `stopTunnel`, `handleAppMessage`.
- `Info.plist`: `NSExtension` dict with `NSExtensionPointIdentifier = com.apple.networkextension.packet-tunnel` and `NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).PacketTunnelProvider`.

`Apps/macOS/Agent/`:

- `main.swift`: top-level entry, bootstraps `CellTunnelLog`, installs SIGINT and SIGTERM handlers, runs `dispatchMain()`.

`Apps/macOS/Entitlements/`:

- `Agent.entitlements` and `TunnelProvider.entitlements`: NE entitlement plus App Group.

`Sources/CellTunnelCore/`:

- `RelayControlMessage.swift` and `RelayControlFramer.swift`: wire format shared with the iPhone control channel.

## Step 5 in-progress state (resume here)

`PacketTunnelProvider.swift` has `startTunnel`/`stopTunnel`/`runStartTunnel` written. The full start sequence is wired: parse config, `setTunnelNetworkSettings`, discover iPhone, connect `RelayTransport`, start `ControlChannel`, build `WireGuardRelayBind`, call `WireGuardRuntime.start`. Supporting files exist: `WireGuardRelayBind.swift`, `WireGuardTunnelConfigBuilder.swift`, `DiscoveryServiceWaiter.swift`.

The last edit made to resolve Swift 6 strict-concurrency errors, not yet build-verified:
- `PacketTunnelProvider` marked `@MainActor`.
- `startTunnel` uses the completion-handler override form (not the `async throws` form) because the `async` form trips a non-Sendable-parameter diagnostic on `[String: NSObject]?`.
- The completion handler is wrapped in a `private struct UncheckedSendableBox<Value>: @unchecked Sendable` so the `Task { @MainActor in ... }` can call it.
- `WireGuardRuntime.start(...)` takes `provider: sending NEPacketTunnelProvider`.

Run `SWIFT_MK_SKIP_FETCH=1 make build TARGET=mac CONFIG=Debug` to verify. If concurrency errors remain, the likely fix is making `WireGuardRuntime` accept the provider on the main actor or restructuring so the provider reference never crosses into the actor.

Lint config decision already made and committed across all three SwiftLint configs (`.make/swiftlint.yml`, `.make/.swiftlint.yml`, and repo-root `.swiftlint.yml`, plus the shared `~/Sites/swift-makefile/.make/` copies): `discouraged_optional_collection` and `legacy_objc_type` are disabled. Reason: Apple's `NEPacketTunnelProvider.startTunnel(options:)` forces a `[String: NSObject]?` parameter and `NEIPv6Settings`/`mtu` force `NSNumber`, neither of which can be expressed in Swift value types. Both rules are AST-level with no per-declaration exemption. There are THREE SwiftLint invocation paths and all three must agree: the swift-makefile gate (`--config .make/.swiftlint.yml`), the build-phase `swiftLintAnalyze` (`--config .swiftlint.yml`), and the bare `swiftlint lint --strict` in `BuildActions.swift:319` (no `--config`, uses repo-root `.swiftlint.yml` by default).

## Smoke test target

The WireGuard config used for smoke tests lives at `/Users/agoodkind/Desktop/wireguard-export/example.com only.conf` and lists `AllowedIPs = 208.67.222.222/32, 2620:119:35::35/128`. It points at `home.goodkind.io:51820` as the server. The filename has a space so commands quote the path. The iPhone listener port defaults to 51821 (`Apps/iOS/Services/RelayPortSettings.swift`), set via `--cell-tunnel-port` launch arg or the iPhone Settings row "Listener Port".

## Hard rules

- Use `git -C /path/to/repo <subcommand>`. Bare `git` lands in the wrong worktree under agent isolation.
- Use `make build TARGET=<x>` rather than calling `tuist`, `xcodebuild`, or `swift build` directly. The Make target runs the full lint pipeline.
- Use `${pipestatus[1]:-${PIPESTATUS[0]}}` when piping to `tee` in zsh.
- Do not weaken, disable, baseline, or work around lint findings. Fix code instead. Inline `// swiftlint:disable` is banned by `no_inline_swiftlint_disable`.
- Do not add hardcoded device identifiers (iPhone UDID, hardware UUID, hostname) to source or doc. Read live from `xcrun xcdevice list`, `xcrun devicectl list devices`, `ideviceinfo`, or `system_profiler`.
- Do not propose Personal Hotspot or any tethering equivalent.
- Default to no code comments. Add one only when WHY is non-obvious.

## Remaining tasks

| # | Task | What it produces |
|---|---|---|
| 5 | Finish `PacketTunnelProvider.startTunnel` / `stopTunnel` overrides (IN PROGRESS, see below) | extension that parses the WG config from `protocolConfiguration.providerConfiguration["wireguardConfig"]`, applies `setTunnelNetworkSettings`, brings up Discovery + RelayTransport + ControlChannel + WireGuardRelayBind + WireGuardRuntime |
| 6 | Implement `CellTunnelAgent` XPC plumbing | `AgentControlMessage` Codable enum; `AgentTunnelController` owning `NETunnelProviderManager` and the `NEVPNStatusDidChange` observer; `AgentXPCServer` decoding requests; agent advertises endpoint at `/tmp/io.goodkind.celltunnel-agent.sock` and idle-times-out after 60s |
| 7 | Implement CLI side | `Sources/CellTunnelCore/AgentClient.swift` (spawns agent if absent, opens XPC, sends Codable messages); `Tools/CellTunnelCtl/main.swift` consumes `AgentClient` and maps each subcommand to an `AgentControlMessage` case |
| 8 | Implement `handleAppMessage` in the extension | `ProviderControlMessage` Codable envelope; the agent forwards a subset of agent messages down to the extension via `NETunnelProviderSession.sendProviderMessage` |
| 9 | End-to-end smoke through the tunnel | `make install-helper`, approve VPN config sheet, `celltunnelctl start`, `ping -c 5 208.67.222.222`, `curl https://api.ipify.org` returns cellular carrier egress IP, iPhone log shows `pdp_ip0`, speedtest recorded |

Two design points to know:

1. The `startTunnel(options:completionHandler:)` override on `NEPacketTunnelProvider` takes Apple's `[String: NSObject]?` signature, which trips `discouraged_optional_collection`, and the `NSNumber` network-settings values trip `legacy_objc_type`. Both rules are disabled in the shared SwiftLint config (the `swift-makefile` repo root `.swiftlint.yml`, which the build fetches into `.make/swiftlint.yml`) for these unavoidable Apple-API spellings. The provider uses the framework types directly, with no inline disables and no type-hiding shims.
2. The agent and CLI talk over XPC. The CLI (`Tools/CellTunnelCtl/main.swift` via `AgentClient`) spawns the agent on demand with `Process`. The agent hosts an `NSXPCListener.anonymous()` and archives its `endpoint` with `NSKeyedArchiver` to `/tmp/io.goodkind.celltunnel-agent.sock`; the CLI reads that endpoint back with `NSKeyedUnarchiver` and dials it via `NSXPCConnection(listenerEndpoint:)`. This avoids a fixed Mach service registration. The agent self-terminates after a 60-second idle timeout and on SIGINT/SIGTERM. The agent binary path is overridable via an environment variable, otherwise resolved as a sibling of the CLI executable.

## Future-work follow-ups

- Adopt Wi-Fi Aware (iOS 26+ cross-platform peer-to-peer standard) as an alternative to `includePeerToPeer = true` (which today wraps AWDL). New Network framework surface.
- Graduate the agent from spawn-on-demand to `SMAppService.loginItem` once development settles. The XPC surface stays the same; the agent binary moves into a host `.app` bundle's `Contents/Library/LoginItems/`.
- Bring back a Mac GUI as a second XPC client of the agent. `AgentClient` is shareable across CLI and GUI.

## Tuist project regeneration

`swift Tools/cell-tunnel-dev.swift generate` regenerates `CellTunnel.xcworkspace`. The build prologue calls it. The generator skips re-running `tuist install` and `tuist generate` when nothing changed. The cache lives at `.build/CellTunnelDev/project-fingerprint.txt` and stores a fingerprint of `Project.swift`, `Tuist.swift`, `Tuist/Package.swift`, and the resolved `DEVELOPMENT_TEAM`. Delete that file to force a fresh regen.

The signing team gets pinned into the generated project from `signingConfig().developmentTeam`. `Project.swift` reads `TUIST_DEVELOPMENT_TEAM` first then `DEVELOPMENT_TEAM`. The default lives at `defaultDevelopmentTeam` in `Tools/CellTunnelDev/Support.swift`.

## iPhone log viewing

`swift Tools/cell-tunnel-dev.swift iphone-logs --app` streams the iPhone syslog over USB via `idevicesyslog`. Flags:

- `--app`: filter to lines mentioning `CellTunnelPhone` or `io.goodkind.celltunnel`.
- `--simulator`: stream Mac-side `log stream` with predicate `subsystem == "io.goodkind.celltunnel"`.
- `--device <udid>`: pin to a specific iPhone.

`idevicesyslog` and `xcrun xctrace` need a USB cable. `xcrun devicectl` works over WiFi when the iPhone and Mac are on the same network or paired via Apple ID. The iPhone CoreDevice hostname is `<name>.coredevice.local`.

## Style rules for any doc you touch

- Lead each section with what the program does, subject-verb-object.
- Internal labels come after the behavior they refer to.
- One thought per sentence. No em-dashes.
- No "now", "was", "previously", "we changed". State the current state. History is in git.
- Ground every claim in the conversation or the source tree. Do not invent file paths or function names without checking.

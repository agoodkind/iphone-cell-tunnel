# Cell Tunnel Agent Entry Point

## Project goal

Cell Tunnel routes Mac internet traffic through an iPhone's native cellular interface. The Mac encrypts each outbound IP packet with WireGuard, ships the encrypted UDP datagram to the iPhone over a Network framework connection, and the iPhone forwards each datagram out the cellular radio to a hosted WireGuard server. Replies retrace the same path.

The use case is education and research.

**Hard rule:** Do not enable iOS Personal Hotspot. Do not propose Personal Hotspot or the macOS `en7` interface as the Mac-to-iPhone link. The iPhone app binds its WireGuard UDP egress with `requiredInterfaceType = .cellular`, which uses the regular cellular APN and is what the project routes around hotspot to obtain.

## Components

| Component | Path | Role |
|---|---|---|
| `celltunnelctl` | `Tools/CellTunnelCtl/main.swift` | User-facing CLI; thin `NSXPCConnection` client of the agent. |
| `CellTunnelAgent` | `Apps/macOS/Agent/` | User-land macOS app registered as a LaunchAgent via `SMAppService.agent`. Owns the `NETunnelProviderManager` and forwards control messages to the extension over `NETunnelProviderSession.sendProviderMessage`. |
| `CellTunnelTunnelProvider` | `Apps/macOS/TunnelProvider/` | Packet-tunnel `NEAppExtension` embedded in `CellTunnelAgent.app/Contents/PlugIns/`. Owns the data path: WireGuard, relay transport, discovery. |
| `CellTunnelPhone` | `Apps/iOS/` | iOS foreground app. Hosts the relay listener and the cellular-bound `WireGuardDatagramRelaySession`. |
| `CellTunnelCore` | `Sources/CellTunnelCore/` | Shared XPC protocol, relay control framer, wire models. |
| `CellTunnelLog` | `Sources/CellTunnelLog/` | Subsystem-pinned `os.Logger` categories. Subsystem is `io.goodkind.celltunnel`. |

## Transports

The Network framework primitives in the provider (`NWBrowser`, `NWListener`, `NWConnection`, `includePeerToPeer = true`) make the Mac-to-iPhone path transport-agnostic. USB-C CDC-NCM, shared Wi-Fi LAN, and AWDL all work without code changes. The iPhone-to-server leg is cellular UDP, pinned by `Apps/iOS/Services/WireGuardDatagramRelaySession.swift`.

## Configuration source of truth

`Config/Constants.xcconfig` holds bundle identifiers, mach service name, executable name, and app group. `Config/local.xcconfig` (gitignored) holds `DEVELOPMENT_TEAM`, `CODE_SIGN_IDENTITY`, and `CODE_SIGN_STYLE`. Copy `Config/local.xcconfig.example` to seed it. `Config/debug.xcconfig` and `Config/release.xcconfig` include both.

`Project.swift` wires `Configuration.debug(xcconfig:)` and `Configuration.release(xcconfig:)`. Target `bundleId` values reference xcconfig variables as `$(AGENT_BUNDLE_ID)` etc. `make xcconfig-generate-config` renders every `*.template` under `Templates/` through `swift-mk render-batch`, substituting `[[KEY]]` from the same xcconfig values, into the destinations listed under `XCCONFIG_RENDER_PLANS` in the `Makefile`. The TargetScript.pre on `CellTunnelCore` and `CellTunnelAgent` re-renders at xcodebuild time so the files survive a `tuist generate` cleanup.

## Build and install

`make build TARGET=daemon|mac|iphone-simulator|iphone-device|all CONFIG=Debug|Release` is the build entrypoint. `TARGET=` is mandatory; bare `make build` errors. `make install-mac` copies the built agent app to `/Applications/CellTunnel/CellTunnelAgent.app` and launches it once so `SMAppService.agent.register()` runs. `make iphone-install` installs and launches `CellTunnelPhone` on the connected device.

`Products/celltunnelctl` is built alongside the daemon target. Subcommands: `status`, `check`, `start-discovery`, `stop-discovery`, `discover`, `probe`, `select <serviceID>`, `start --config <path> [--relay <host:port>]`, `stop`.

## Tooling layout

`swift-makefile` (consumed via `bootstrap.mk`) owns the shared lint, format, baseline, analyze, audit, update, and fetch policy. Its `xcconfig.mk` module provides the `xcconfig-generate-config` and `xcconfig-generate-project` Make targets, and its `swift-mk` binary exposes the `render-batch` subcommand used by those targets. `Tools/Package.swift` depends on the local `swift-makefile` checkout and imports `SwiftMkCore` so `Tools/CellTunnelDev/BuildActions.swift` calls `Lint.runLint(context:)` and `Lint.runFmt(context:)` directly rather than reimplementing lint config resolution.

`Tools/CellTunnelDev/` owns project generation, build orchestration, install, activation, iPhone log streaming, and audit. The Make targets call `swift Tools/cell-tunnel-dev.swift <command>`.

## General rules

- The `Makefile` and `bootstrap.mk` are the canonical `swift-makefile` consumer interface.
- `SWIFT_MK_DEV_DIR` makes `bootstrap.mk` fetch from a local `swift-makefile` checkout instead of GitHub.
- Project-specific build, generation, test, device, signing, and notarization workflows live in Swift under `Tools/`.
- Do not commit `Config/local.xcconfig`, secrets, certificates, WireGuard private keys, P12 passwords, or notary credentials.
- Do not weaken lint, audit, analyzer, signing, or verification gates.
- Do not edit generated Xcode projects, generated workspaces, build output, or product output.

## Diagnostic rules

- Treat source state, build output, installed bundle state, agent XPC state, NetworkExtension state, route table state, Mac unified logs, and iPhone unified logs as separate proof surfaces.
- Before claiming agent behavior, capture `launchctl print gui/$(id -u)/io.goodkind.celltunnel-agent`, `Products/celltunnelctl status`, and `log show --predicate 'subsystem == "io.goodkind.celltunnel"' --info --last 30s`.
- Before claiming relay discovery or selection behavior, capture `Products/celltunnelctl discover` and the selected relay endpoint.
- Before claiming route behavior, capture `route -n get` for each tested IPv4 and IPv6 destination, `ifconfig` for the active `utun` interface, and `netstat -ibn` counters before and after traffic.
- Before any route-mutating test, use narrow `AllowedIPs` host routes. Do not test broad default routes until a scoped IPv4 and IPv6 proof passes and the user has explicitly approved the broader swap.
- Before claiming traffic uses cellular, capture iPhone-side evidence showing `interface: pdp_ip0` and `uses cell`, plus app logs showing `cellular wireguard udp` send and receive activity. A successful Mac `curl` alone is not cellular proof.
- After a failed or interrupted route test, run `Products/celltunnelctl stop`, verify `Products/celltunnelctl status` reports `running=false`, and verify the scoped routes no longer point at the old `utun` interface before retrying.

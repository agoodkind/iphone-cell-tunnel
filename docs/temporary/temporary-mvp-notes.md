# Cell Tunnel context for the next agent

This file is the single durable handoff for the Cell Tunnel project. An agent with zero prior context can pick up the work by reading it first.

## Where we are right now (top of the file, read first)

The project has been rewritten Swift-native. The Go daemon is gone. The Phase 1 Swift daemon is feature-complete on paper. The build is green for the daemon, the Mac app, and the iPhone app. The end-to-end tunnel does not yet work because the XPC handshake between `celltunnelctl` and `celltunneld` fails: `celltunnelctl status` returns `error_kind=daemon_unavailable`.

The architectural decision to fix this was made at the end of the last session: **collapse the helper split back into a single `celltunneld` daemon registered via `SMAppService.daemon`.** The split was added to keep dev iteration fast (small privileged surface, big user-mode binary that restarts freely), but it required passing the utun file descriptor across processes. Modern Apple XPC APIs (`XPCSession`, `XPCListener`) do not expose fd passing through their Codable convenience surface, and Apple's `SMAppService.daemon` actually supports silent reinstalls when the Team ID is stable, so the dev-loop pain that motivated the split was overstated. Collapsing the split removes the fd-passing problem, lets the entire codebase use modern `XPCListener` / `XPCSession`, and trades one TouchID prompt at install time for a much simpler lifecycle.

The user explicitly said "I want it all to be modern" and "Yes, collapse to one celltunneld as SMAppService.daemon." That is the next agent's job.

## What the project does in plain language

The Mac wants to use the internet through the iPhone cellular signal instead of through wifi. Traffic on the Mac is encapsulated and forwarded over USB to the iPhone. The iPhone forwards each packet over its cellular interface to a hosted server we own. The hosted server unwraps and forwards each packet to the real internet.

The use case is education and research. The motivation is to route Mac traffic through the iPhone cellular signal **without** using iOS Personal Hotspot. Carriers may rate-limit Personal Hotspot data while leaving native cellular data unmetered, so we want native cellular egress from the iPhone, not the tethered path. That is why the project carries a custom iPhone app instead of using the stock hotspot. Do not propose Personal Hotspot as the answer for the Mac to iPhone link, because Personal Hotspot is exactly the thing we are routing around.

The path is:

1. The Mac sends each packet to a fake network card on the Mac.
2. A Mac program picks each packet up and wraps it in WireGuard encryption.
3. The Mac hands each wrapped packet to a USB Multiplex daemon Apple ships in macOS.
4. That daemon forwards the bytes over USB to a port the iPhone has open on its own loopback.
5. An iPhone app reads each wrapped packet and sends it out over cellular to a server we own.
6. The server unwraps each packet and sends it to the real internet.
7. Replies come back the same way.

Names for the pieces:

- The Mac daemon is `celltunneld`. It runs as root and owns the WireGuard client device plus all route changes.
- The Mac CLI is `celltunnelctl`. It talks to `celltunneld` over a Unix socket.
- The iPhone app is `CellTunnelPhone`. It must run in the foreground while testing.
- The fake network card on the Mac is `utun`.
- The USB Multiplex daemon Apple ships is `usbmuxd`. It listens on `/var/run/usbmuxd`.
- The Go-side wrapper for usbmuxd lives at `Daemon/internal/usbmuxd/`. It uses the `github.com/danielpaulus/go-ios` library.

## Current state

Build is green for every target. `swift Tools/cell-tunnel-dev.swift build daemon`, `... build mac`, and `... build iphone-device` all exit 0. The iPhone app installs and runs. The Mac app installs via `... install-helper` and TouchID has been approved once. `launchctl print system/io.goodkind.celltunneldhelperd` shows the privileged helper registered. `launchctl print gui/501/io.goodkind.celltunneld` shows the user-mode daemon registered.

The user-mode daemon launches on demand and reaches `dispatchMain`. The `/tmp/celltunneld.stdout.log` file confirms every step from `step=boot` through `step=ready entering dispatchMain` fires cleanly.

The end-to-end tunnel does not yet work because of an XPC API mismatch. The client `celltunnelctl` uses modern `XPCSession`. The daemon `ControlServer` was switched to `NSXPCListener` during the helper-split work to keep the helper-side `NSXPCConnection` fd-passing path consistent. The two APIs are not interoperable. `Products/celltunnelctl status` returns `error_kind=daemon_unavailable socket_path=io.goodkind.celltunneld.xpc`.

The bench result we still trust is 925 Mbps Mac to iPhone over CDC-NCM UDP via `NWConnection` (commit `7055f81`). The throughput goal is to approach cellular's roughly 300 Mbps end to end through the tunnel once the daemon actually moves bytes.

## Goal, in one line

Fast, durable, reliable, latest technology. Match or approach the roughly 300 Mbps the cellular link is capable of, end to end through the tunnel.

## Next agent: collapse the helper split

This is the actionable handoff. The architecture decision was made; the work was not yet executed.

Target architecture after this work:

- `celltunneld` is the single Mac daemon. Privileged. Runs as root. Registered via `SMAppService.daemon` with a one-time TouchID prompt.
- `celltunneld` opens utun directly, runs WireGuard via WireGuardKit and the existing `LoopbackBindBridge`, manages routes via the existing `RouteManager`, runs the existing `ControlServer` for `celltunnelctl`, runs the existing `ControlChannel` to the iPhone.
- `ControlServer` uses modern `XPCListener`. `TunnelControlClient` uses modern `XPCSession`. Codable wire format end to end. No `NSXPCListener` or `NSXPCConnection` anywhere in the project.
- `celltunneldhelperd` is deleted. `Sources/CellTunnelDaemonHelper/` is deleted. `Sources/CellTunnelDaemon/HelperClient.swift` is deleted. `Sources/CellTunnelCore/HelperXPCContract.swift` is deleted.
- `Apps/macOS/LaunchAgents/io.goodkind.celltunneld.plist` is deleted. `Apps/macOS/LaunchDaemons/io.goodkind.celltunneldhelperd.plist` is replaced by a new `Apps/macOS/LaunchDaemons/io.goodkind.celltunneld.plist` that points at the embedded daemon binary and declares the `io.goodkind.celltunneld.xpc` Mach service.

Sources to keep and move back into `Sources/CellTunnelDaemon/`:

- `Sources/CellTunnelDaemonHelper/UtunDevice.swift` becomes `Sources/CellTunnelDaemon/UtunDevice.swift` again. The local `ctlInfoIoctl` constant in that file should go back to importing `CTLIOCGINFO` from `WireGuardKitC` since the daemon now links WireGuardKit.
- `Sources/CellTunnelDaemonHelper/RouteManager.swift` becomes `Sources/CellTunnelDaemon/RouteManager.swift` again.

Sources to rewrite back to modern XPC:

- `Sources/CellTunnelDaemon/ControlServer.swift` was rewritten by Subagent F to use `NSXPCListener` plus an `@objc CellTunnelDaemonControlProtocol`. Restore the pre-Subagent-F version that used `XPCListener(service:targetQueue:incomingSessionHandler:)`. Reference: `git -C /Users/agoodkind/Sites/iphone-cell-tunnel show 27e3c35:Sources/CellTunnelDaemon/ControlServer.swift` is the original modern-XPC version, before the helper split landed.
- `Sources/CellTunnelCore/TunnelControlClient.swift` was rewritten this session to use `NSXPCConnection`. Restore the prior `XPCSession`-based version. Reference: `git -C /Users/agoodkind/Sites/iphone-cell-tunnel show 8985796:Sources/CellTunnelCore/TunnelControlClient.swift` was the modern-XPC client.
- `Sources/CellTunnelDaemon/DaemonState.swift` and `Sources/CellTunnelDaemon/DaemonState+Tunnel.swift` reference `HelperClient` for utun open and route install. Replace those calls with direct `UtunDevice()` and `RouteManager` usage. Delete the `HelperClient` field on `DaemonState`.
- `Sources/CellTunnelDaemon/main.swift` still has the print-debug instrumentation added this session (`emitDiagnostic` function plus the `step=` lines). Strip it once the daemon is verified to work.

Tuist and build system changes:

- Delete the `celltunneldhelperd` target and scheme from `Project.swift`.
- Delete the helper signing entries in `Tools/CellTunnelDev/Signing.swift`. The bundle no longer copies the helper binary, the helper plist, or the user agent plist into the app bundle. `packageMacBundle` should put a single launchd plist at `Contents/Library/LaunchDaemons/io.goodkind.celltunneld.plist` and a single binary at `Contents/Library/LaunchServices/celltunneld`.
- Update `Apps/macOS/Services/TunnelHelperService.swift` and `Apps/macOS/Services/MacHelperCommand.swift` to register only the one daemon via `SMAppService.daemon(plistName:)`. Drop the `SMAppService.agent(...)` call.
- Update `Tools/CellTunnelDev/HelperVerification.swift` to verify only one binary and one launchctl target.
- Update `Tools/CellTunnelDev/ActivationActions.swift` to bootout only `system/io.goodkind.celltunneld` on uninstall, and remove only the one app.
- Update the install verification: do not poll for a running PID. Load-on-demand XPC daemons stay `state = not running` until a client connects. The correct verification is an actual `XPCSession`-based ping to `daemonControlMachServiceName` that asserts the daemon answers a `status` RPC.

Makefile and AGENTS.md update:

- Add `make daemon-reload` that runs `sudo launchctl kickstart -k system/io.goodkind.celltunneld`. Document it.
- Add `make install` that wraps `swift Tools/cell-tunnel-dev.swift install-helper`. Document it.
- Add `make uninstall` that wraps `swift Tools/cell-tunnel-dev.swift uninstall-helper`. Document it.
- Add `make iphone-install` that wraps `swift Tools/cell-tunnel-dev.swift activate iphone`. Document it.
- Add `make smoke` that runs the post-install celltunnelctl sequence against the smoke config at `/Users/agoodkind/Desktop/wireguard-export/example.com only.conf`. Document it.
- Add `make logs` that tails both daemon OSLog and the iPhone syslog. Document it.
- Update `AGENTS.md` "General rules" so agents reach for the `make` targets above as canonical entry points, with the existing `swift Tools/cell-tunnel-dev.swift <subcommand>` calls as the underlying implementation. The `make build TARGET=<x>` guardrail stays.

Acceptance for this work:

1. `make build TARGET=mac` exits 0.
2. `make install` succeeds. The TouchID prompt fires only on the first run; subsequent runs do not re-prompt.
3. `Products/celltunnelctl status` returns a Codable response, not `daemon_unavailable`.
4. `make daemon-reload` rebuilds, swaps the bundled binary, and kickstarts the daemon. Subsequent `celltunnelctl status` calls work immediately.
5. Code is free of `NSXPCConnection` and `NSXPCListener`. The repo grep confirms.

After this lands, the next step is the actual Phase 1 smoke (task #25): `make iphone-install`, `make install`, `make smoke`, verify ping and curl through the tunnel, verify iPhone log shows `pdp_ip0`, record speedtest result.

## Architecture pivot: Swift-native rewrite

The Mac daemon rewrites to Swift. Go was a day-0 mistake. Every component has a Swift equivalent (see AGENTS.md "Architecture direction"). Phase 1 ships a plain Swift launchd daemon. Phase 2 is a P0 fast-follow: migrate to `NEPacketTunnelProvider` inside `CellTunnelMac.app` for Apple-managed VPN lifecycle. Phase 2 starts the moment Phase 1 stabilizes and the throughput goal is met.

The Go daemon (`Daemon/`), `go-ios` usage, and cgo DNS-SD bindings retire as the Swift daemon takes over. WireGuardKit replaces `wireguard-go`. `NWConnection` replaces the `usbmuxd` dial path. `NWBrowser` replaces the cgo Bonjour code. Route management calls BSD routing socket syscalls from Swift directly via the `Darwin` module.

As of the commit "Delete Daemon Go tree and add NWConnection UDP bench listener", the entire `Daemon/` directory, `go.work`, and `go.work.sum` are deleted. The Swift CLI (`celltunnelctl`), Mac app, and launch daemon plist still reference the deleted binary names at runtime; they will fail to start a tunnel until the Phase 1 Swift daemon replaces them. The iPhone app is unaffected.

## Exp 2 result: UDP over CDC-NCM via NWConnection

Mac TX averaged 1.16 Gbps over a 60-second probe (8.72 GB total). iPhone RX averaged ~925 Mbps sustained during the receive window before iOS killed the unthrottled listener under Network framework memory pressure. That is 38 to 48 times the current `usbmuxd` path of 24 Mbps end-to-end.

The Mac-to-iPhone leg is no longer the bottleneck. Cellular (~300 Mbps) is now the cap, which is the desired state. In production, the Mac throttles to match cellular and packet loss goes to zero.

Test setup:
- Mac dials iPhone via Bonjour `_celltunnelbench._udp`, resolved over the developer CDC-NCM interface, IPv6 link-local.
- Bench listener at `Apps/iOS/Services/BenchListener.swift` is gated by `--cell-tunnel-bench-mode` launch arg. Auto-starts on app init when the flag is present, zero footprint otherwise.
- Mac bench at `/tmp/celltunnel-bench-mac.swift` is a single-file Swift script (run with `swift /tmp/celltunnel-bench-mac.swift`). Not in the repo tree; can graduate to `Tools/` later if useful.
- `NSBonjourServices` arrays in both `Apps/iOS/Info.plist` and `Apps/macOS/Info.plist` now include `_celltunnelbench._udp`.

Decision: the Phase 1 Swift daemon uses `NWConnection` UDP over CDC-NCM as the Mac-to-iPhone transport. No need to try CoreDevice tunnel or NWConnection TCP; this is fast enough.

## Transport options for the Mac to iPhone link

The Mac to iPhone link is the suspected bottleneck. None of these have been compared head to head with isolated measurements yet. The candidates:

- **`usbmuxd`** (today). Apple's USB Multiplex daemon. The end-to-end pipeline through this transport measures around 24 Mbps for WireGuard datagrams. Whether the cap is in `usbmuxd` itself, in our framing code, in WireGuard, or in the iPhone receive code is the question Exp 1 in the experiment plan answers.
- **Developer CDC-NCM interface via Apple's `Network.framework`** (untried). The interface where Go's `net.Dial` hit the 18 second TCP death over link-local IPv6. UDP and `NWConnection` TCP on this interface have not been tested. Apple's own tools use `NWConnection` and do not appear to hit the bug; observed not proven. Exp 2 and Exp 3 probe this path.
- **CoreDevice / RemoteXPC tunnel** (Apple's name, not "tunneld"). Modern Apple device communication. Used by Xcode and `devicectl`. Community reports suggest higher throughput than `usbmuxd`; not measured here. `go-ios` wraps it but is blocked on a `gvisor` version conflict that broke our build last attempt and was reverted. Two ways forward if revisited: fork `go-ios` with a minimal patch, or call Apple's `CoreDevice.framework` directly from Swift.
- **Wi-Fi Aware** (iOS 26+, new in WWDC25). Direct device-to-device Wi-Fi peer transport with authentication and high throughput. Wireless, not USB. Untried.

## Aspirations and pending architecture decisions

- The experiment sequence (Exp 1 -> 2 -> 3, defined below) decides the next transport. Each one is cheap and isolates one variable. Run them in order and let the data choose.
- **Network Extension on iPhone** (`NEPacketTunnelProvider`) is a separate concern from throughput. It addresses durability and background execution. The packet-capture half of the API does not apply because our packets originate on the Mac, not on iOS. The extension lifecycle is what we want for "iOS keeps the listener alive in the background, survives lock screen and app suspension." Tracked as task #17.
- WireGuard stays as the wire format for now, because it gives us "single UDP destination" on the cellular leg and avoids NAT or source IP rewriting that raw packet tunneling would force.
- **Personal Hotspot is explicitly off the table** because the use case is bypassing it. See AGENTS.md for the grounded version of this rule, including which CDC-NCM interfaces do and do not activate Personal Hotspot.

## What the working setup looks like, end to end

Phase 1 smoke targets:

- IPv4: `208.67.222.222`
- IPv6: `2620:119:35::35`

The WireGuard config used for the smoke test lives at `/Users/agoodkind/Desktop/wireguard-export/example.com only.conf`. That file lists `AllowedIPs = 208.67.222.222/32, 2620:119:35::35/128`. It points at `home.goodkind.io:51820` as the hosted server. The filename contains a space, so every command quotes the path.

iPhone UDID for the test device: `00008150-000249060A00401C`.

To run the smoke test:

1. Build a fresh daemon with `swift Tools/cell-tunnel-dev.swift build daemon`.
2. Bring up the iPhone app with `swift Tools/cell-tunnel-dev.swift activate iphone`. The app auto-starts its relay listener.
3. Find the iPhone listener port via `Products/celltunnelctl probe`. Look for `service=iPhone ...:<port>`.
4. Unload any launchd-managed daemon with `sudo launchctl bootout system/io.goodkind.celltunneld` if loaded. Then start the fresh one under root with `sudo Products/celltunneld serve`.
5. Start the tunnel via the usbmuxd transport with `Products/celltunnelctl start --config "/Users/agoodkind/Desktop/wireguard-export/example.com only.conf" --relay "usbmuxd:00008150-000249060A00401C:<port>"`.
6. Smoke test with `ping -c 5 208.67.222.222` and `ping6 -c 5 2620:119:35::35`.
7. Wait past 20 seconds and ping again to confirm the tunnel survives. The usbmuxd transport stays up. The old TCP-over-link-local path used to die at exactly 18 seconds.
8. `Products/celltunnelctl stop` removes the routes.

## The 18 second bug, the diagnosis, and the fix

What we saw: every Mac-to-iPhone TCP connection over IPv6 link-local on a USB-NCM interface died after exactly 18 seconds, on first connect or on reconnect. The iPhone-side TCP would retransmit data that Mac never acknowledged. The Mac eventually read `ENETUNREACH` (`no route to host`) and gave up.

What we proved with a wire-level capture on `-i any`:

- Mac sends the initial hello frame and iPhone acknowledges it.
- iPhone sends a path-status frame back.
- Mac receives the bytes at the application layer (the daemon logs "received path status").
- Mac never transmits the TCP acknowledgement for those bytes on any interface (en9, en11, en0, or loopback).
- iPhone retransmits ten or more times.
- After about eighteen seconds the iPhone-side `NWConnection` raises `Operation timed out` (`Network.NWError 60`).

Why this happens: macOS routes link-local IPv6 traffic to a USB-NCM iPhone in a way that breaks for our raw `net.Dial` call. Apple's `Network.framework` and the `usbmuxd` daemon both know how to do this correctly. Go's `net.Dial` does not. The Mac kernel either drops the ACKs at the routing layer or sends them out the wrong physical interface, with no log surface we can see.

The fix: route the Mac to iPhone leg through `usbmuxd` instead of dialing the iPhone over link-local IPv6. `usbmuxd` is Apple's canonical USB Multiplex daemon used by Xcode, Apple Configurator, and libimobiledevice. It exposes any TCP port the iPhone has open on its loopback as a stream over a Unix socket. Apple owns the transport end to end. There is no Bonjour, no link-local IPv6, and no 18 second death.

How we wired it in:

- A new Go package `Daemon/internal/usbmuxd` wraps `github.com/danielpaulus/go-ios`. It exposes `ListDevices()` plus `Dial(deviceID, port)`.
- `TCPRelayClient` now takes an injectable `RelayDialer` function. The default keeps the plain TCP dial path. `buildRelayClient` in `Daemon/internal/tunnel/relay_client.go` picks the usbmuxd dialer when the local relay endpoint starts with `usbmuxd:`.
- The endpoint format is `usbmuxd:<UDID>:<port>`. The CLI parses it as `host="usbmuxd:<UDID>"` plus `port=<port>`. Both Swift `socketAddress` and Go `Endpoint.SocketAddress` special-case the `usbmuxd:` prefix to skip IPv6 bracketing.
- `buildLocalRelayPreservations` in `Daemon/internal/tunnel/route_plan.go` skips the local-relay route preservation entirely for `usbmuxd:` endpoints since there is no IP route to preserve.

## How to fall back to the old TCP path (for diagnosis)

The Bonjour-discovered IPv6 link-local endpoint still parses and dials. It also still dies at 18 seconds. It is useful only for reproducing the bug, not as a working transport. Example: `Products/celltunnelctl start --config "..." --relay "[fe80::ccf4:53ff:fe4a:3c90%en9]:<port>"`.

## Build commands and their guardrails

The build command requires an explicit target. Bare `swift Tools/cell-tunnel-dev.swift build` errors out. This prevents an agent from quietly building half the system and calling it done.

Targets:

- `daemon` builds `celltunneld` and `celltunnelctl` only. This is the fast path.
- `mac` builds daemon, ctl, and `CellTunnelMac.app` packaged and signed.
- `iphone-simulator` builds daemon, ctl, and the iOS simulator app.
- `iphone-device` builds daemon, ctl, and the iOS device app with codesign.
- `all` runs every target.

Every target always runs generate, Swift lint, Go lint, log audit, and Go audit before any compile. None of those can be skipped from the command line. The build prints SHA256 fingerprints for `celltunneld` and `celltunnelctl` at the end so stale-helper mismatches are visible.

If you pipe the wrapper output through `tee`, read `${PIPESTATUS[0]}` instead of `$?`. `tee` always succeeds and masks the wrapper real exit code.

The Makefile mirrors this. `make build TARGET=daemon`, `make build TARGET=mac`, and so on all work. Bare `make build` errors with the same usage.

## Daemon log level

`celltunneld` defaults to `slog.LevelDebug`. Override at process start with `CELL_TUNNEL_LOG_LEVEL=debug|info|warn|warning|error`. The constant lives in `Daemon/cmd/celltunneld/main.go`.

## Control socket location

The control socket defaults to `/var/run/io.goodkind.celltunnel/control.sock` on both the daemon side (`Daemon/cmd/celltunneld/main.go`) and the Swift CLI side (`Sources/CellTunnelCore/TunnelControlClient.swift`). Both sides honor `CELL_TUNNEL_CONTROL_SOCKET` at runtime to override the path. A Swift test at `Tests/CellTunnelCoreTests/TunnelControlSocketPathTests.swift` reads the Go source and fails if the default literal or the env var name drifts apart between the two languages.

## iPhone listener port

The iPhone-side relay listener binds to a fixed port. Default 51821. The value comes from `Apps/iOS/Services/RelayPortSettings.swift`. Three ways to set it:

- Default. If nothing is configured the app uses 51821.
- Launch argument `--cell-tunnel-port <port>`. The Mac CLI `swift Tools/cell-tunnel-dev.swift activate iphone --port <port>` passes this through.
- iPhone Settings section. The "Listener Port" row in the iPhone UI lets the operator edit and apply a new port. The new value persists in `UserDefaults` under `io.goodkind.celltunnel.relay.port`.

The relay listener does not pick an ephemeral port any more. Bonjour still publishes the listener too, but the canonical CLI start uses the explicit port: `start --relay usbmuxd:<UDID>:51821`.

## Tuist project generation

`swift Tools/cell-tunnel-dev.swift generate` is the only thing that should regenerate `CellTunnel.xcworkspace`. The build prologue calls it. The generator now skips re-running `tuist install` and `tuist generate` when nothing relevant has changed. The cache lives at `.build/CellTunnelDev/project-fingerprint.txt` and stores a fingerprint of `Project.swift`, `Tuist.swift`, `Tuist/Package.swift`, and the resolved `DEVELOPMENT_TEAM`. Delete that file to force a fresh regen.

The signing team gets pinned into the generated project from `signingConfig().developmentTeam`. The Tuist evaluator does not see normal env vars, so `generateProject` passes `DEVELOPMENT_TEAM` and `TUIST_DEVELOPMENT_TEAM` through to `tuist install` and `tuist generate`. `Project.swift` reads `TUIST_DEVELOPMENT_TEAM` first then `DEVELOPMENT_TEAM`. If neither is set, `Project.swift` omits the signing keys and Xcode falls back to its own logic. The default development team source is `defaultDevelopmentTeam` in `Tools/CellTunnelDev/Support.swift`.

## Throughput instrumentation

Both sides emit 1 Hz throughput summaries to log. On the Mac daemon side `TCPRelayClient` keeps `datagramsSent`, `datagramsReceived`, `bytesSent`, `bytesReceived` as `atomic.Uint64` counters. The `throughputLoop` goroutine wakes every second, computes deltas, and calls `emitThroughputSample`. The hot path no longer logs per datagram.

On the iPhone side `PhoneRelayController+Throughput.swift` runs a Task that samples the `TunnelCounters` struct every second and logs deltas. Hot-path debug and info logs in `PhoneRelayController.swift` and `WireGuardDatagramRelaySession.swift` are stripped. State transitions still log at `.notice` and errors at `.error`.

## Performance tunables landed

- WireGuard MTU bumped from 1280 to 1420 in `Daemon/internal/tunnel/config.go`.
- TCP_NODELAY on the relay TCP dial in `Daemon/internal/tunnel/relay_client.go`. Does nothing for the usbmuxd path because that path is a Unix socket. Will matter for the eventual tunneld TCP6 path.
- WireGuard config `PersistentKeepalive = 5` in `/Users/agoodkind/Desktop/wireguard-export/example.com only.conf`.
- Hot-path log strip described above.
- Atomic counters described above.

## iPhone log viewing

`swift Tools/cell-tunnel-dev.swift iphone-logs` streams the full iPhone syslog over USB via `idevicesyslog`.

Useful flags:

- `--app` filters to lines mentioning `CellTunnelPhone` or `io.goodkind.celltunnel`.
- `--simulator` streams Mac-side `log stream` with a predicate on the `io.goodkind.celltunnel` subsystem. This catches simulator runs.
- `--device <udid>` pins to a specific iPhone.

If `xcdevice list` returns no device, the auto-pick fails. This sometimes happens when the iPhone screen has been locked recently. Pass `--device 00008150-000249060A00401C` to bypass.

## Discovery and the manual selection flow

`celltunnelctl probe` shows the daemon status and the Bonjour services it sees. `celltunnelctl discover` starts daemon-owned discovery, waits for at least one service with a preferred endpoint, and lists everything it finds. Discover never auto-selects. The operator picks the service.

Two CLI paths bring up the tunnel after `discover`:

- Canonical: pass the usbmuxd endpoint explicitly on `start --relay usbmuxd:<UDID>:<port>`. This sidesteps the 18 second bug.
- Alternate: `celltunnelctl select <service-id>` writes the chosen service into the daemon selection slot, then `start --config <path>` with no `--relay` uses that selection. The selected endpoint stays the bonjour-resolved one. With a physical iPhone over USB-NCM that means link-local IPv6, which dies at 18 seconds. The alternate path is fine for simulator runs and for testing daemon plumbing.

## Daemon-running mode

The daemon needs root for two things: opening `utun` and writing the routing socket. Both come from `sudo`.

`launchctl bootout system/io.goodkind.celltunneld` removes any pre-installed launchd-managed daemon so the sudo-run binary can take the socket without a fight. The launchd-managed install path uses `SMAppService` and needs a TouchID plus System Settings approval. That install path is not used in this dev loop.

For the dev loop:

1. Run `sudo launchctl bootout system/io.goodkind.celltunneld` if a previous install is loaded.
2. In a dedicated terminal run `sudo /Users/agoodkind/Sites/iphone-cell-tunnel/Products/celltunneld serve`.
3. Run `Products/celltunnelctl status` to confirm the CLI can reach the running daemon.

## Files most likely to be relevant

Mac daemon, Go:

- `Daemon/cmd/celltunneld/main.go`: entry point, env-var log level, env-var control socket.
- `Daemon/internal/tunnel/relay_client.go`: TCP relay client, pluggable dialer, heartbeat goroutine, usbmuxd dispatch via `buildRelayClient`.
- `Daemon/internal/tunnel/relay_protocol.go`: wire frame definitions including the `RelayOperationKeepAlive` opcode (value 10).
- `Daemon/internal/tunnel/route_plan.go`: installs one host route per WireGuard `AllowedIPs` entry. Skips local relay preservation for `usbmuxd:` endpoints.
- `Daemon/internal/tunnel/route_executor.go`: actual route installation over the BSD routing socket.
- `Daemon/internal/tunnel/wireguard_runtime.go`: wires the relay bind to the relay client.
- `Daemon/internal/usbmuxd/usbmuxd.go`: thin wrapper around go-ios for `ListDevices` and `Dial`.
- `Daemon/internal/discovery/types.go`: `Endpoint.SocketAddress` formats relay endpoint strings and special-cases `usbmuxd:` prefixes.
- `Daemon/internal/controlserver/service.go`: gRPC handlers that pass the parsed relay endpoint through to the runtime.

Mac CLI and shared, Swift:

- `Sources/CellTunnelCore/TunnelControlCLI.swift`: `celltunnelctl` command dispatch.
- `Sources/CellTunnelCore/TunnelControlModels.swift`: `TunnelRelayEndpoint.parse` recognizes the `usbmuxd:` prefix and stores `host="usbmuxd:<UDID>"` plus `port=<port>`. `socketAddress` skips bracketing for that prefix.
- `Sources/CellTunnelCore/RelayProtocol.swift`: Swift mirror of the wire frame definitions including `.keepAlive = 10`.
- `Sources/CellTunnelCore/TunnelControlClient.swift`: default control socket path, env var name `CELL_TUNNEL_CONTROL_SOCKET`, and `resolvedTunnelControlSocketPath()` helper.

iPhone app, Swift:

- `Apps/iOS/CellTunnelPhoneApp.swift`: auto-starts the relay on launch when the `--cell-tunnel-start-relay` argument is present.
- `Apps/iOS/Services/PhoneRelayController.swift`: `NWListener` with `includePeerToPeer = true`, TCP keepalive options, and a heartbeat task that emits `.keepAlive` frames every 8 seconds.
- `Apps/iOS/Services/PhoneRelayController+PeerLifecycle.swift`: single-connection enforcement via `replacePeerConnections`.
- `Apps/iOS/Services/WireGuardDatagramRelaySession.swift`: cellular `NWConnection` UDP to the hosted server. Gates `requiredInterfaceType = .cellular` out for simulator builds.

Tooling:

- `Tools/CellTunnelDev/main.swift`: subcommand dispatch.
- `Tools/CellTunnelDev/BuildDispatch.swift`: required-target build dispatcher with SHA256 fingerprint output.
- `Tools/CellTunnelDev/IPhoneLogActions.swift`: `iphone-logs` subcommand.
- `Tools/cell-tunnel-dev.swift`: outer wrapper that builds and runs the `CellTunnelDev` binary. Propagates exit codes correctly.

## Open tasks worth knowing about

- #10 The 18 second bug deeper write-up. Still smelly: we bypassed it with usbmuxd but never root-caused. Working theory (not proven): Apple's TCP stack does not ACK correctly on link-local IPv6 over USB-NCM for raw Go `net.Dial`, while `usbmuxd` dodges it by not relying on that route. Whether Apple's `NWConnection` dodges it too is what Exp 3 measures.
- #13 The usbmuxd transport itself. Done end to end for IPv4.
- #14 Diagnose tunnel throughput cap vs Personal Hotspot baseline. Partial. The 24 Mbps measurement is end-to-end. The cap location inside the pipeline is not isolated. The three-experiment plan below addresses this.
- #16 Retired. CoreDevice tunneld attempt failed on a `gvisor` dependency conflict in `go-ios` and was reverted with no main-tree cruft. Future CoreDevice work, if any, calls Apple's `CoreDevice.framework` from Swift instead of going through `go-ios`.
- #17 Wrap iPhone relay in Network Extension for background durability. Queued. Picks up after the transport choice is settled.
- #20 Exp 1: raw byte throughput through usbmuxd, no WireGuard. Isolates whether the cap is in usbmuxd or in our framing code.
- #21 Exp 2: raw UDP throughput over CDC-NCM link-local IPv6. Tests whether UDP on the developer CDC-NCM interface beats usbmuxd. No TCP, no usbmuxd, no WireGuard.
- #22 Exp 3: `NWConnection` TCP probe over CDC-NCM. Only run if Exp 1 or Exp 2 leave TCP-vs-Go-stack questions open.

## What is definitively known to work

- IPv4 ping and curl through the tunnel exit via the iPhone cellular signal. Confirmed with iPhone OSLog showing `interface: pdp_ip0[lte]` and `uses cell`.
- The tunnel stays up indefinitely across restart cycles when dialed via `usbmuxd:<UDID>:<port>`.
- Daemon SHA fingerprints print at the end of every build target.
- The iPhone simulator app accepts the daemon TCP connection on `[::1]:<port>` (loopback). The tunnel works for the non-cellular leg. The iOS simulator gates the cellular requirement out so traffic exits via the Mac host network.

## What does not work yet

- IPv6 ping replies do not return from the hosted WireGuard server during this session window. The wire capture proves the Mac sends v6 echoes through the relay and the iPhone forwards them via cellular. The server does not respond. The user is investigating this on the server side.
- The auto-pick discover is non-deterministic when multiple iPhone interfaces are visible.
- The launchd-managed daemon install path needs a System Settings plus TouchID approval. It is not in the standard dev loop.

## Style rules for any new doc you write

- Lead each section with what the program does, in subject-verb-object form.
- Name internal labels only after the behavior they refer to.
- Keep sentences short with one thought per sentence.
- Use no emdashes and no en-dashes.
- Write no "now", "was", "previously", or "we changed". The doc should state the current state. History lives in git.
- Use the conversation context to ground claims. Do not make up file paths or function names without checking first.

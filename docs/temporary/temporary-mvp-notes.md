# Cell Tunnel context for the next agent

This file is the single durable handoff for the Cell Tunnel project. An agent with zero prior context can pick up the work by reading it first.

## What the project does in plain language

The Mac wants to use the internet through the iPhone cellular signal instead of through wifi. Traffic on the Mac is encapsulated and forwarded over USB to the iPhone. The iPhone forwards each packet over its cellular interface to a hosted server we own. The hosted server unwraps and forwards each packet to the real internet.

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

## Current state, in one paragraph

IPv4 traffic works end-to-end through the relay over USB and exits via the iPhone cellular signal. The tunnel survives stop and start cycles. The route table for `208.67.222.222/32` resolves through our `utun` interface during a session. IPv6 also works at the relay level on the Mac and iPhone side, but the hosted WireGuard server is currently not replying to v6 echoes during this session window. The user is investigating the v6 problem on the server side. Phase 1 acceptance is met for IPv4 over the usbmuxd transport, pending the server v6 fix.

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

- #10 The 18 second bug deeper write-up. The functional fix via usbmuxd is shipped. This would be a longer post-mortem if anyone wants one.
- #13 The usbmuxd transport itself. Done end to end for IPv4. The iPhone-side `includePeerToPeer = true` could be dropped now since the usbmuxd path uses iPhone loopback. Bonjour discovery still needs it for the wifi fallback that does not exist yet.

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

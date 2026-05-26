# Cell Tunnel Agent Entry Point

## Project goal (read this first)

Cell Tunnel gives the Mac internet through the iPhone's cellular signal **without enabling iOS
Personal Hotspot**. Use case is education and research: carriers may rate-limit hotspot data
while leaving native cellular data unmetered, so Mac traffic is forwarded over USB or Wi-Fi to
a custom iPhone app that egresses the bytes through its own cellular UDP connection.

**Hard rule: do not enable Personal Hotspot on the iPhone, and do not propose Personal Hotspot
as the Mac-to-iPhone link.** When Personal Hotspot is on, iOS egresses through the hotspot
APN and the carrier accounts the data as hotspot data. That is the thing the project routes
around.

The macOS "iPhone" network service backed by `en7` is the Personal Hotspot interface and only
materializes when Personal Hotspot is enabled. Do not use it.

Other USB-attached interfaces appear on macOS without enabling Personal Hotspot: the iOS 16+
developer CDC-NCM interfaces (on this machine they appear as `en8`, `en9`, and `en11`),
`usbmuxd`, and the CoreDevice / RemoteXPC tunnel. None of those activate Personal Hotspot on
the iPhone. The iPhone app makes the cellular UDP egress itself with
`requiredInterfaceType = .cellular`, which binds to the regular cellular APN, not the hotspot
APN. The carrier sees encrypted UDP from the iPhone's regular cellular IP, indistinguishable
from any other iOS app's cellular UDP.

The choice between the non-hotspot transports is an open performance question. The current
`usbmuxd` path measures around 24 Mbps end-to-end. The cap location is not isolated yet. See
`docs/temporary/temporary-mvp-notes.md` for the experiment plan.

## Architecture direction: Swift-native

The Mac daemon and supporting tooling rewrite to Swift. Go was a day-0 mistake. Every component
the Go side covers has a first-party or well-known Swift equivalent:

- WireGuard: **WireGuardKit** (SwiftPM, wraps `wireguard-go` via a C-ABI bridge; used by Mullvad
  and the official iOS/macOS WireGuard apps).
- Mac to iPhone transport: **`NWConnection`** on `Network.framework`. The CDC-NCM interface is
  directly addressable from Swift; no `usbmuxd` or `go-ios` needed.
- Bonjour / DNS-SD: **`NWBrowser`** / **`NWListener`** on `Network.framework`. Replaces the cgo
  `dns_sd.h` bindings.
- BSD routing socket: direct `socket(PF_ROUTE, ...)` syscalls from Swift via the `Darwin` module.
- utun: `WireGuardKit` manages this internally. Direct `socket(PF_SYSTEM, SYSPROTO_CONTROL)`
  from Swift if a separate path is ever needed.
- gRPC control plane: `grpc-swift` (Apple-supported), or a thinner Codable-over-UDS layer.

Phase 1 ships the rewritten `celltunneld` as a plain Swift launchd daemon. This keeps the dev
loop close to the current one (sudo for dev, `SMAppService` for install).

Phase 2 is a P0 fast-follow once Phase 1 stabilizes: migrate `celltunneld` to a
`NEPacketTunnelProvider` inside `CellTunnelMac.app`. That gives Apple-managed VPN lifecycle, no
sudo, system-handled auto-start, and a cleaner long-term home for the daemon.

Read these documents before editing this repository:

- [Architecture](docs/architecture/mvp-wireguard-relay.md)
- [Engineering Rules](docs/development/engineering-rules.md)
- [Tooling](docs/development/tooling.md)
- [Signing](docs/development/signing.md)
- [MVP Device Check](docs/runbooks/mvp-device-check.md)
- [MVP CLI Check](docs/runbooks/mvp-cli-check.md)

## Agent entry points (use these first)

Reach for these `make` targets before any direct `swift Tools/cell-tunnel-dev.swift <subcommand>` call. The make layer is the canonical surface.

- `make build TARGET=daemon|mac|iphone-simulator|iphone-device|all`. The `TARGET=` argument is mandatory. Bare `make build` errors out by design so an agent cannot quietly build half the system.
- `make install`. Builds the Mac app, installs to `/Applications/CellTunnelMac.app`, and registers the daemon via `SMAppService.daemon`. TouchID prompts once. Subsequent runs swap the bundled binary without re-prompting.
- `make uninstall`. Unregisters the daemon and removes the installed Mac app.
- `make daemon-reload`. After a `make build TARGET=daemon` swap, runs `sudo launchctl kickstart -k system/io.goodkind.celltunneld` so the daemon loads the new binary. Use this for fast dev iteration.
- `make iphone-install`. Builds `iphone-device`, installs and launches `CellTunnelPhone` on the connected iPhone with the auto-start flag.
- `make smoke`. Runs the post-install celltunnelctl sequence against the smoke config at `/Users/agoodkind/Desktop/wireguard-export/example.com only.conf`: status, start-discovery, discover, select first result, start, ping and curl both smoke targets.
- `make logs`. Tails the Mac daemon OSLog and the iPhone syslog filtered to the relay.

If a target above does not exist yet, the docs are ahead of the code. Add the missing target to the Makefile rather than working around it with raw `swift Tools/cell-tunnel-dev.swift` calls.

General rules:

- Use the committed `Makefile` and `bootstrap.mk` as the canonical `swift-makefile` consumer interface.
- Use `swift-makefile` for shared lint, format, baseline, analyze, audit, update, and fetch policy.
- Use `SWIFT_MK_DEV_DIR` from the shell environment to fetch `swift-makefile` assets from a local checkout.
- Keep project-specific build, generation, test execution, device, signing, notarization, packaging, and run workflows in Swift under `Tools/`.
- Wire project-specific Swift workflows into `swift-makefile` variables instead of duplicating shared targets.
- Do not add committed project-local shell scripts.
- Do not edit generated Xcode projects, generated workspaces, build output, product output, or generated Go tooling.
- Keep secrets, private keys, certificates, WireGuard private keys, P12 passwords, and notary credentials out of Git, logs, and chat.
- Do not weaken lint, audit, analyzer, signing, or verification gates to pass a handoff.

Diagnostic rules:

- Treat diagnostics as separate proof surfaces. Do not collapse source state, build output, installed helper state,
  daemon control state, route table state, Mac logs, iPhone logs, and phone UI into one assumption.
- Before testing route or tunnel behavior, verify the installed privileged helper matches the current build with
  `shasum -a 256 Products/Debug/macosx/CellTunnelMac.app/Contents/Library/LaunchServices/celltunneld /Applications/CellTunnelMac.app/Contents/Library/LaunchServices/celltunneld`.
  If the hashes differ, refresh the helper through the canonical helper install path before testing and record the new
  hashes.
- Before claiming daemon behavior, capture `launchctl print system/io.goodkind.celltunneld`, `pgrep -fl celltunneld`,
  `Products/celltunnelctl status`, and the relevant line-numbered range from `/var/log/celltunneld.stderr.log`.
  Do not sample daemon logs with `tail`; use `wc -l`, `nl -ba`, and `sed -n` with explicit line ranges.
- Before claiming relay discovery or selection behavior, capture `Products/celltunnelctl discover`, the selected relay
  endpoint, and the active WireGuard config path.
- Before claiming route behavior, capture `route -n get` for every tested IPv4 and IPv6 destination, `ifconfig` for the
  active `utun` interface, and `netstat -ibn` counters before and after traffic.
- Before any route-mutating test, use narrow `AllowedIPs` host routes. Do not test broad default routes until a scoped
  IPv4 and IPv6 proof passes and the user has explicitly approved the broader route swap.
- Before claiming traffic works, test both the IPv4 and IPv6 destinations from the active WireGuard config, and keep
  success and failure evidence for each family separate.
- Keep WireGuard tunnel proof separate from target-service proof. A `curl` result like `404 Not Found` can still be a
  valid transport proof when the target service is expected to return it, but only if route lookups and `utun` counters
  also show the scoped destination traversed the tunnel.
- Before claiming traffic is using cellular, capture iPhone-side evidence for the `CellTunnelPhone` UDP flow showing
  `interface: pdp_ip0` and `uses cell`, plus app logs showing `cellular wireguard udp` send and receive activity.
  A successful Mac `curl` alone is not cellular proof.
- When using iPhone logs, prefer `idevicesyslog` filtered to `CellTunnelPhone`, `cellular wireguard udp`,
  `received hosted datagram`, `pdp_ip0`, and `uses cell`. If `idevicesyslog` is left running after an interrupted test,
  stop it before handing off.
- For USB relay tests, do not assume the transport is wrong just because the phone UI says `Error`. First split the
  evidence into relay discovery, Mac-to-phone TCP relay frames, iPhone cellular UDP sends, iPhone cellular UDP receives,
  WireGuard handshake traffic, and inner IPv4 or IPv6 response traffic.
- When checking physical-device state, capture `xcrun devicectl device info lockState` and the `CellTunnelPhone`
  process entry from `xcrun devicectl device info processes`. If physical-device UI state matters, ask the user for a
  screenshot directly; only use tool-captured screenshots for simulator UI.
- After every failed or interrupted route test, run `Products/celltunnelctl stop`, verify `Products/celltunnelctl status`
  reports `running=false`, and verify the scoped routes no longer point at the old `utun` interface before retrying.

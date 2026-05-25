# Cell Tunnel Agent Entry Point

Read these documents before editing this repository:

- [Architecture](docs/architecture/mvp-wireguard-relay.md)
- [Engineering Rules](docs/development/engineering-rules.md)
- [Tooling](docs/development/tooling.md)
- [Signing](docs/development/signing.md)
- [MVP Device Check](docs/runbooks/mvp-device-check.md)
- [MVP CLI Check](docs/runbooks/mvp-cli-check.md)

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

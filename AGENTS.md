# Cell Tunnel Agent Entry Point

## Project goal

Cell Tunnel routes Mac internet traffic through an iPhone's native cellular interface, for education and research. See `docs/architecture.md` for the data path.

**Hard rule:** Do not enable iOS Personal Hotspot. Do not propose Personal Hotspot or the macOS `en7` interface as the Mac-to-iPhone link. The iPhone app binds its WireGuard UDP egress with `requiredInterfaceType = .cellular`, which uses the regular cellular APN and is what the project routes around hotspot to obtain.

## Architecture doc

`docs/architecture.md` is the source of truth for the data path, the per-component responsibilities, the hard constraints, the rationale for running the iPhone relay inside an `NEPacketTunnelProvider`, and the source-of-truth map.

## How to operate here (read this first)

This file is the map, not the source of truth. The source of truth is the code and the live tooling; find current behavior by querying them, not by trusting prose (including this file).

- **Commands:** `make help` lists every build, lint, test, format, and install target with a one-line description. It is generated from the live Makefile, so it never drifts. Start there.
- **Operational and diagnostic actions are Swift, never shell.** Every project operation is a subcommand of the `CellTunnelDev` CLI in `Tools/CellTunnelDev/`, invoked as `swift Tools/cell-tunnel-dev.swift <command>` (run it with no args for the full list). Reading iPhone logs, browsing for the relay, bringing the tunnel up, collecting the device unified log: all are commands there. Shell scripts are banned in this repo. If an operation you need is missing, add a Swift subcommand modeled on an existing one (for example `iphone-logs`), make `make lint` pass, then use it. Do not hand-author throwaway shell pipelines.
- **`celltunnelctl` is the agent client; query it for the current command set.** Use the `CellTunnelDev` `relay-*` commands (`relay-up --config <path>`, `relay-status`, `relay-reload --config <path>`, `relay-down`) for tunnel operations, which poll the agent deterministically rather than racing its idle timeout. `celltunnelctl --help` lists the raw client commands, and the agent-owned config library lives behind `celltunnelctl configs`.
- **Logs are mandatory evidence. Run them; never infer behavior from a grep snippet or from prose (including this file).** Reading a few source lines and reasoning from them is the documented failure mode here. The only valid basis for a claim about agent, tunnel, relay, route, or phone behavior is live tool output. Two log commands, both sanctioned and both runnable from this environment:
  - Mac side (agent and tunnel-provider unified log): `swift Tools/cell-tunnel-dev.swift mac-logs [--last <dur>] [--stream] [--contains <text>]`. It execs `/usr/bin/log` so the interactive zsh `log` builtin never shadows it; it has no device dependency, so always run it.
  - iPhone side: `swift Tools/cell-tunnel-dev.swift iphone-logs [--last <dur>] [--contains <text>] [--predicate <p>] [--follow]`. It collects the device unified log and prints the project subsystem with history, including an error that already fired and latched `lastError`.

  Never decline a log command on a guess that it needs `sudo` or cannot run here. Run it. If it genuinely fails, paste the real error and reason from that, not from an assumption.
- **`running=true` is not proof the relay is hosted.** In `relay-status`, `running` is only the macOS VPN session state, which the system keeps marked connected independently of the ephemeral agent, and `peer=wireguard-configured` only means a config exists. The iPhone-facing relay, its control listener and UDP data bridge, exists only while a relay is actively hosted, and it is torn down on stop or when the agent idle-exits. Confirm hosting from `peers`/`links` in `relay-status` and the control-listener line in `mac-logs`, never from `running` alone.
- **Verify the real state before acting.** The user drives branches, commits, merges, and the physical device directly. Run `git -C <repo> status`/`log`, `xcrun devicectl list devices`, `celltunnelctl status`, and the log commands above before concluding anything. Treat source, build output, installed bundle, agent XPC, NetworkExtension, route table, and the two unified logs as separate proof surfaces (see Diagnostic rules). Identifiers, signing, and ports come from the xcconfig files (see Configuration source of truth); do not hardcode them.

## Non-negotiable house rules

- **Never touch lint baselines.** Fix every finding in code. No inline `swiftlint:disable`. The shared config under `.make/` is fetched from `swift-makefile` and is not locally editable, so code is the only lever. `make lint` must be green before any build or merge.
- **Every Swift file gets the canonical header and `// MARK: -` dividers.** Top of file, before imports:

  ```
  //
  //  <FileName>.swift
  //  <ModuleName>
  //
  //  Created by Alexander Goodkind <alex@goodkind.io> on <YYYY-MM-DD>.
  //  Copyright © <YYYY>
  //
  ```

  Author and email are the repo git identity (`git config user.name` / `user.email`). The date is the file's original creation date (`git log --diff-filter=A --follow --format=%ad --date=short -- <path>`), today for a new file. Use `//` not `///` for the header (a free-floating `///` trips `orphaned_doc_comment`); put `///` on the declarations. Add `// MARK: -` section dividers throughout.
- **Banned in production code:** `Task.sleep`/`sleep` (use `DispatchSource`/`asyncAfter`) and `try?` (handle errors explicitly). Route CLI output through `FileHandle.standardOutput`/`CellTunnelLog`, never `print`. Name magic numbers. These are enforced by `swiftcheck-extra` and `log-audit`.
- **No em-dashes anywhere**, including Unicode escapes; the commit hook blocks them.
- **A `DispatchSource`/`NWListener`/`NWConnection` callback on a `@MainActor` type must be `@Sendable`.** Inside an `@MainActor` class, a closure handed to `DispatchSource.makeTimerSource(...).setEventHandler`, `NWListener.stateUpdateHandler`, or `NWConnection` handlers inherits MainActor isolation unless marked `@Sendable`. When the dispatch queue then runs it off the main thread, libdispatch traps with `BUG IN CLIENT OF LIBDISPATCH: Block was expected to execute on queue [com.apple.main-thread]` and the process dies. In a NetworkExtension provider this crashes the extension and the on-demand rule relaunches it in a loop. Mark such handlers `@Sendable [weak self]` and hop back with `Task { @MainActor in ... }` for any MainActor state.
- **Builds run in the foreground** so their output is visible. Build before install (the install targets deploy a prebuilt bundle).
- **The relay's interface choices are set only through `RelayConfiguration`.** The egress interface type (the radio the WireGuard egress pins to) and the carrying interface are read from `RelayConfiguration` (`Sources/CellTunnelRelay/RelayConfiguration.swift`), the single source of truth. Never hardcode an interface type or an interface name in the binders, the data plane, or the composition presets; thread it from `RelayConfiguration`. A future stored setting or UI control replaces the values by constructing `RelayConfiguration` differently at the composition root, with no change to the data plane.
- **Bonjour service names come from `stableHostName()`, never `ProcessInfo.processInfo.hostName`.** The agent's control and relay services are named from `stableHostName()` (`Apps/macOS/Agent/AgentControlListener.swift`), which returns the ComputerName. `ProcessInfo.processInfo.hostName` returns the transient mDNS hostname, which Cloudflare WARP sets to `connectivity-check.warp-svc`, so using it would show that as the peer on the iPhone.

## Components

See `docs/architecture.md` ("Component responsibilities" and "User interface") for the component map and the data path. The code under each target's directory is the source of truth for internals.

## App behavior and transports

See `docs/architecture.md` ("User interface", "Path selection") for how the app is structured and how the iPhone carries traffic across links. Two operational specifics live here: the app targets iOS 26, and Catalyst signs from `Apps/iOS/Entitlements/CellTunnelPhone-Catalyst.entitlements`, which keeps the app group, drops the NetworkExtension entitlement, and adds a mach-lookup allowance for the agent mach service, with the Catalyst minimum macOS derived from the iOS deployment target.

## Configuration source of truth

`Config/Constants.xcconfig` holds bundle identifiers, mach service name, executable name, and app group. `Config/local.xcconfig` (gitignored) holds `DEVELOPMENT_TEAM`, `CODE_SIGN_IDENTITY`, and `CODE_SIGN_STYLE`. Copy `Config/local.xcconfig.example` to seed it. `Config/debug.xcconfig` and `Config/release.xcconfig` include both. iOS device signing reads an App Store Connect API key from `Config/local.signing.env` (gitignored); copy `Config/local.signing.env.example` to seed it.

Targets reference the xcconfig values rather than literal identifiers. A make target renders the generated config from those values, and the render runs again at build time so the generated files survive project regeneration. Do not edit generated config by hand; change the xcconfig values.

## Build and install

`README.md` is the user-facing build, install, and run quickstart, and `make help` lists every target. Two agent-specific notes: `TARGET=` is mandatory for `make build` (bare `make build` errors), and the `install` targets deploy a prebuilt bundle, so build the target first. `make install-mac` copies the agent app to `/Applications/CellTunnel/CellTunnelAgent.app`, then always restarts the launchd service so the freshly built binary is the one running.

`Products/celltunnelctl` is built alongside the daemon target and is the agent control client; run `celltunnelctl --help` for the current command set. The agent owns one config library, exposed both there (`celltunnelctl configs`) and in the Mac Catalyst app. The library model (UUID identity, profile stamping, and the non-mutating boot assertion) lives in `docs/architecture.md` under "Configuration and routes".

## Clean launch procedure

Run every step from a known state. Verify each precondition with a command before the next step. Assume nothing about prior state.

1. Build before install. `make install-mac` and `make iphone-install` install a prebuilt bundle and do not build it. After `make clean` or any source change, build the target first:
   - macOS: `make build TARGET=mac CONFIG=Debug`, then `make install-mac CONFIG=Debug`.
   - iPhone: `make build TARGET=iphone-device CONFIG=Debug`, then `make iphone-install CONFIG=Debug`.
   The iPhone device build needs the App Store Connect API key in `Config/local.signing.env` (see README "Signing"); with it unset the build falls back to the interactive Xcode account.
2. One iPhone only. A booted simulator running `CellTunnelPhone` reaches the agent over loopback and can be adopted as the relay instead of the physical device, and a simulator cannot egress over cellular. Before any relay test run `xcrun simctl list devices booted` and `xcrun simctl shutdown <udid>` for each booted `CellTunnelPhone` simulator so only the physical device dials the agent.
3. Bring up the Mac tunnel: `swift Tools/cell-tunnel-dev.swift relay-up --config <path>`. It returns `running=true` with `routes=not-installed`: the Mac VPN is connected immediately with no iPhone present. The agent hosts the link and the extensions dial it, so no relay selection is needed.
4. Confirm the relay is hosted, then wait for the iPhone link. The relay is explicit: the agent idle-exits when no relay is active and does not auto-restore one at boot. If `relay-status` shows `peers=0`/`links=0` and `mac-logs` shows no control-listener line, the relay is down, so bring it back with step 3 rather than assuming a torn-down session is reusable. When the iPhone extension dials in, the agent signals the extension and `relay-status` flips to `routes=installed`. Routes track the link, so a test before `routes=installed` measures nothing through the tunnel. Link failover between interfaces during a live relay is automatic and traffic-driven, so a single interface dropping does not need a restart.
5. Pin the throughput test to the server the config routes. The scoped config routes only specific destinations, so an auto-selected speedtest server goes direct and the headline is the physical link, not the tunnel. Pin the test to the one server whose IP the config's `AllowedIPs` lists (the config comments name the server id and IP). Confirm the traffic crossed the relay with the counter delta from `relay-status` before and after: `mac_datagrams_from_server` and `mac_bytes_in` must rise by the bulk transferred, not a few coordination packets.
6. Probe reachability per protocol, not just speed, and confirm each crossed the relay. The relay carries any inner protocol opaquely, and a destination may answer one protocol and not another, so test the one you mean and read the `relay-status` counter delta around it (`mac_datagrams_from_server` and `mac_bytes_in` for replies received, `mac_datagrams_to_server` and `mac_bytes_out` for traffic sent).
   - Egress identity. A what's-my-ip test is valid only for the address family whose `ident.me` address is in `AllowedIPs`. The scoped config lists `ident.me` IPv6 (`2a01:4f9:c012:8091::1`), so `curl -6 https://ident.me` routes over the tunnel and returns the server's egress address. The config does not list `ident.me`'s IPv4, so `curl -4 https://ident.me` goes out `en0` natively and returns the Mac's own ISP address; that native result is correct scoping, not the server. To test the IPv4 egress identity, resolve `ident.me`'s current IPv4, add it as a `/32` to `AllowedIPs`, and `relay-reload`; the in-tunnel `curl -4` then returns the server's IPv4 egress. Confirm with `route -n get <ip>` (an in-list destination shows `interface: utun`, an off-list one shows `en0`) and the `relay-status` counter delta.
   - ICMP: `ping 208.67.222.222` for v4 and `ping6 -s 16 2620:fe::fe` for v6. Use `-s 16` for IPv6, because the WireGuard server's own upstream v6 transit drops default-size ICMPv6 echo to some destinations on a path-MTU limit; a default-size v6 ping can read 100% loss while the path works, and a 16-byte payload gets through. A 100% default-size v6 ping is not a relay fault when the smaller ping and TCP and DNS to the same address succeed.
   - TCP: `curl -6 https://[2600:1901:0:b2bd::]/` or another routed host. A TLS certificate error means the TCP connection completed, so the path works even when ICMP to the same host does not. For a host whose address has an all-zero interface id (ends in `::`), `route -n get` can report the native interface even though the `/128` is installed on the `utun` (confirm the `/128` with `netstat -rn -f inet6 | grep utun`); trust the `relay-status` counter delta around the request, not `route -n get`, for that case.
   - DNS: `dig -6 @2620:fe::fe example.com A` (Quad9) or `dig -6 @2620:119:35::35 ...` (OpenDNS), both resolvers in `AllowedIPs`. A `status: NOERROR` answer confirms a routed resolver replies over the tunnel.
7. Never widen routes to test. Do not switch to an all-traffic (`0.0.0.0/0, ::/0`) config to measure throughput. An all-traffic config makes the tunnel the Mac default route, so a relay stall takes the Mac fully offline. Use the scoped config that already routes the test target.
8. Tear down cleanly. `swift Tools/cell-tunnel-dev.swift relay-down`, then confirm `relay-status` reports `running=false` and `route -n get default` points at the physical interface (`en0`), not a `utun`.

## Tooling layout

The shared lint, format, baseline, analyze, audit, update, and fetch policy comes from the `swift-makefile` consumer setup, reached through the make targets. Project-specific build, generation, install, activation, iPhone log streaming, and audit live in the `CellTunnelDev` tool, invoked as `swift Tools/cell-tunnel-dev.swift <command>`.

## General rules

- The `Makefile` and `bootstrap.mk` are the canonical `swift-makefile` consumer interface.
- `SWIFT_MK_DEV_DIR` makes `bootstrap.mk` fetch from a local `swift-makefile` checkout instead of GitHub.
- Project-specific build, generation, test, device, signing, and notarization workflows live in Swift under `Tools/`.
- Do not commit `Config/local.xcconfig`, secrets, certificates, WireGuard private keys, P12 passwords, or notary credentials.
- Do not weaken lint, audit, analyzer, signing, or verification gates.
- Do not edit generated Xcode projects, generated workspaces, build output, or product output.

## Diagnostic rules

- Treat source state, build output, installed bundle state, agent XPC state, NetworkExtension state, route table state, Mac unified logs, and iPhone unified logs as separate proof surfaces.
- Logs come first. Before claiming agent, tunnel, relay, route, or phone behavior, run `mac-logs` and, for phone-side history, `iphone-logs` (see "Logs are mandatory evidence" above), and read the output rather than inferring it.
- Before claiming agent behavior, capture `Products/celltunnelctl check` (agent build identity and config presence) and `Products/celltunnelctl status`, alongside `mac-logs`. For the launchd state directly, `launchctl print gui/$(id -u)/<label>`, where `<label>` is `AGENT_MACH_SERVICE_NAME` from `Config/Constants.xcconfig`, not a literal to memorize.
- Before claiming relay or egress-peer behavior, capture `Products/celltunnelctl peers` (the iPhones dialed into the agent) and `Products/celltunnelctl status` (the carrying link and active relay endpoint).
- Before claiming route behavior, capture `route -n get` for each tested IPv4 and IPv6 destination, `ifconfig` for the active `utun` interface, and `netstat -ibn` counters before and after traffic.
- Before any route-mutating test, use narrow `AllowedIPs` host routes. Do not test broad default routes until a scoped IPv4 and IPv6 proof passes and the user has explicitly approved the broader swap.
- The captured route set is program-owned, not the config's `AllowedIPs`. The relay peer's cryptokey `AllowedIPs` is broadened to `0.0.0.0/0` and `::/0` so WireGuard encrypts any captured packet to the one peer, while `RouteGate` installs only the program's scoped `includedRoutes` (seeded from the config `AllowedIPs` at import) and discards the wide routes WireGuardKit derives. The scoped routes are what the tunnel captures; the wide cryptokey values never reach `includedRoutes`. Change the running tunnel's config, including its route set, without a restart or a VPN profile save with `relay-reload --config <path>`; edit only the `AllowedIPs` line of the config with `sed -i ''` and never `cat` the config, so the `PrivateKey` line is never read into output.
- Before claiming traffic uses cellular, capture iPhone-side evidence showing `interface: pdp_ip0` and `uses cell`, plus app logs showing `cellular wireguard udp` send and receive activity. A successful Mac `curl` alone is not cellular proof.
- After a failed or interrupted route test, run `Products/celltunnelctl stop`, verify `Products/celltunnelctl status` reports `running=false`, and verify the scoped routes no longer point at the old `utun` interface before retrying.

# Cell Tunnel Agent Entry Point

## Project goal

Cell Tunnel routes Mac internet traffic through an iPhone's native cellular interface. The Mac encrypts each outbound IP packet with WireGuard, ships the encrypted UDP datagram to the iPhone over a Network framework connection, and the iPhone forwards each datagram out the cellular radio to a hosted WireGuard server. Replies retrace the same path.

The use case is education and research.

**Hard rule:** Do not enable iOS Personal Hotspot. Do not propose Personal Hotspot or the macOS `en7` interface as the Mac-to-iPhone link. The iPhone app binds its WireGuard UDP egress with `requiredInterfaceType = .cellular`, which uses the regular cellular APN and is what the project routes around hotspot to obtain.

## Architecture doc

`docs/architecture.md` is the source of truth for the data path, the per-component responsibilities, the hard constraints, the rationale for running the iPhone relay inside an `NEPacketTunnelProvider`, and the source-of-truth map.

## How to operate here (read this first)

This file is the map, not the source of truth. The source of truth is the code and the live tooling; find current behavior by querying them, not by trusting prose (including this file).

- **Commands:** `make help` lists every build, lint, test, format, and install target with a one-line description. It is generated from the live Makefile, so it never drifts. Start there.
- **Operational and diagnostic actions are Swift, never shell.** Every project operation is a subcommand of the `CellTunnelDev` CLI in `Tools/CellTunnelDev/`, invoked as `swift Tools/cell-tunnel-dev.swift <command>` (run it with no args for the full list). Reading iPhone logs, browsing for the relay, bringing the tunnel up, collecting the device unified log: all are commands there. Shell scripts are banned in this repo. If an operation you need is missing, add a Swift subcommand modeled on an existing one (for example `iphone-logs`), make `make lint` pass, then use it. Do not hand-author throwaway shell pipelines.
- **`celltunnelctl` is the agent client, not a discovery shortcut.** `Products/celltunnelctl devices` reads the agent's browser snapshot; it returns empty unless discovery was started first (`start-discovery`). Use the `CellTunnelDev` `relay-*` commands, which start discovery and poll deterministically, rather than chaining raw `celltunnelctl` calls and racing the agent's 60s idle timeout.
- **iPhone logs come from the device unified log via Apple's `log collect`.** Run `swift Tools/cell-tunnel-dev.swift iphone-logs [--last <dur>] [--contains <text>] [--predicate <p>] [--follow]`, which collects the device unified log and prints the `io.goodkind.celltunnel` subsystem with history, including a one-time error that latched `lastError`. `--follow` repeats the collect on an interval to approximate a live view. Mac logs: `swift Tools/cell-tunnel-dev.swift mac-logs [--last <dur>]`.
- **Configuration source of truth** is `Config/Constants.xcconfig` (committed) and `Config/local.xcconfig` plus `Config/local.signing.env` (gitignored). Identifiers, signing, and ports come from there; do not hardcode them.
- **Verify the real state before acting.** The user drives branches, commits, merges, and the physical device directly. Run `git -C <repo> status`/`log`, `xcrun devicectl list devices`, `celltunnelctl status`, and the relevant `iphone-logs` before concluding anything. Treat source, build output, installed bundle, agent XPC, NetworkExtension, route table, and the two unified logs as separate proof surfaces (see Diagnostic rules below).

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

## Components

Components are named by target. The code is the source of truth for their internals; find current sources under each target's directory rather than from a path written here.

| Component | Role |
|---|---|
| `celltunnelctl` | User-facing command-line client of the agent. |
| `CellTunnelAgent` | macOS background agent. Owns the Mac VPN configuration, hosts the control link and the relay data listener the iPhone dials, sends the WireGuard server endpoint to the iPhone, and bridges relay datagrams between the Mac extension over loopback and the iPhone. It exits when idle to free resources, but holds that idle timer for the life of the relay so it never kills its own bridge mid-session. |
| `CellTunnelTunnelProvider` | macOS packet-tunnel extension hosted by the agent app. Runs WireGuard and dials the agent over loopback for the relay data plane. |
| `CellTunnelPhoneTunnel` | iOS packet-tunnel extension hosted by the iPhone app. Owns the always-on relay data plane: it dials the Mac to receive the WireGuard server endpoint, keeps a link open to the agent over every reachable local path and carries traffic on the preferred one (failing over to another open link on a send error), forwards datagrams to and from the cellular radio, observes the cellular path, and answers status requests. |
| `CellTunnelPhone` | iOS host app. Drives the extension with an on-demand rule, polls status, and shows a minimal first-party status screen. Holds no relay data plane itself. |
| `CellTunnelCore` | Shared control wire protocol, framer, wire models, and shared keys. |
| `CellTunnelLog` | Pinned logging subsystem and categories. |

## Transports

The Network framework primitives in the provider make the Mac-to-iPhone path transport-agnostic. USB-C CDC-NCM, a USB-C Ethernet adapter, shared Wi-Fi LAN, and AWDL all work without code changes. The iPhone keeps a link open over every reachable path at once and carries traffic on one of them, so a path loss moves traffic to an already-open link with no reconnect. The carrying link is chosen by a preference order, USB over Wi-Fi LAN over AWDL held as scores in `RelayLinkScorer`, or by an explicit interface override; the choice is the pure `RelayLinkPolicy.chooseCarrying`, recomputed only when a link opens or closes and read as one cached pointer off the packet path. A link closes only when its connection errors or a send on it fails, the reliable signal a UDP path went away, so the carrying link fails over on a send error with no timer or heartbeat. The iPhone-to-server leg is cellular UDP, pinned to the cellular interface so it uses the regular cellular APN.

## iPhone app behavior

`CellTunnelPhone` is always-on with no Start control. The relay data plane runs in the iPhone packet-tunnel extension, which the system keeps up via an on-demand rule, so it keeps forwarding while the app is backgrounded. The app starts the tunnel on launch and resumes the status poll when it becomes active. It shows a minimal first-party status screen with relay state, cellular egress, throughput, and dropped counts, and a DEBUG console shows live detail including the last error. The app targets iOS 26.

## Configuration source of truth

`Config/Constants.xcconfig` holds bundle identifiers, mach service name, executable name, and app group. `Config/local.xcconfig` (gitignored) holds `DEVELOPMENT_TEAM`, `CODE_SIGN_IDENTITY`, and `CODE_SIGN_STYLE`. Copy `Config/local.xcconfig.example` to seed it. `Config/debug.xcconfig` and `Config/release.xcconfig` include both.

Targets reference the xcconfig values rather than literal identifiers. A make target renders the generated config from those values, and the render runs again at build time so the generated files survive project regeneration. Do not edit generated config by hand; change the xcconfig values.

## Build and install

`make build TARGET=daemon|mac|iphone-simulator|iphone-device|all CONFIG=Debug|Release` is the build entrypoint. `TARGET=` is mandatory; bare `make build` errors. `make install-mac` copies the built agent app to `/Applications/CellTunnel/CellTunnelAgent.app` and launches it once so `SMAppService.agent.register()` runs. `make iphone-install` installs and launches `CellTunnelPhone` on the connected device.

`Products/celltunnelctl` is built alongside the daemon target. Running with no arguments or `--help`/`-h` prints usage. Subcommands: `status`, `check`, `devices` (lists discovered relay devices), `select <n|serviceID>` (selects by 1-based index or service id), `start --config <path> [--relay <host:port>]`, `stop`. Every command except `start` returns after one round-trip to the agent. `start` waits (bounded) for the tunnel session to reach connected before returning, so a single `start` reports the real outcome (`running=true`/`routes=installed` on success). The agent hands the provider a concrete relay service name resolved from its always-warm Bonjour browser (a still-visible persisted selection, else the first device), so the extension connects on the first attempt without a cold per-start discovery race.

## Clean launch procedure

Run every step from a known state. Verify each precondition with a command before the next step. Assume nothing about prior state.

1. Build before install. `make install-mac` and `make iphone-install` install a prebuilt bundle and do not build it. After `make clean` or any source change, build the target first:
   - macOS: `make build TARGET=mac CONFIG=Debug`, then `make install-mac CONFIG=Debug`.
   - iPhone: `make build TARGET=iphone-device CONFIG=Debug`, then `make iphone-install CONFIG=Debug`.
   The iPhone device build reads the App Store Connect API key from `Config/local.signing.env` (`APPLE_NOTARY_KEY_ID`, `APPLE_NOTARY_ISSUER_ID`, `APPLE_NOTARY_KEY_PATH`); copy `Config/local.signing.env.example` to seed it. With the env unset the build falls back to the interactive Xcode account.
2. One iPhone only. A booted simulator running `CellTunnelPhone` reaches the agent over loopback and can be adopted as the relay instead of the physical device, and a simulator cannot egress over cellular. Before any relay test run `xcrun simctl list devices booted` and `xcrun simctl shutdown <udid>` for each booted `CellTunnelPhone` simulator so only the physical device dials the agent.
3. Bring up the Mac tunnel: `swift Tools/cell-tunnel-dev.swift relay-up --config <path>`. It returns `running=true` with `routes=not-installed`: the Mac VPN is connected immediately with no iPhone present. The agent hosts the link and the extensions dial it, so no relay selection is needed.
4. Wait for the iPhone link before testing. When the iPhone extension dials the agent relay listener, the agent signals the extension and `relay-status` flips to `routes=installed`. Routes track the link, so a test before `routes=installed` measures nothing through the tunnel. The reconnect path is not yet automatic, so run `clean-reinstall` before each test rather than reusing a torn-down session.
5. Pin the throughput test to the server the config routes. The scoped config routes only specific destinations, so an auto-selected speedtest server goes direct and the headline is the physical link, not the tunnel. Pin the test to the one server whose IP the config's `AllowedIPs` lists (the config comments name the server id and IP). Confirm the traffic crossed the relay with the counter delta from `relay-status` before and after: `mac_datagrams_from_server` and `mac_bytes_in` must rise by the bulk transferred, not a few coordination packets.
6. Never widen routes to test. Do not switch to an all-traffic (`0.0.0.0/0, ::/0`) config to measure throughput. An all-traffic config makes the tunnel the Mac default route, so a relay stall takes the Mac fully offline. Use the scoped config that already routes the test target.
7. Tear down cleanly. `swift Tools/cell-tunnel-dev.swift relay-down`, then confirm `relay-status` reports `running=false` and `route -n get default` points at the physical interface (`en0`), not a `utun`.

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
- To read iPhone-side history (any error that already fired, including one that latched `lastError`), use `swift Tools/cell-tunnel-dev.swift iphone-logs [--last <dur>] [--contains <text>] [--follow]`. It reads the device unified log via `log collect`, which carries history; `--follow` repeats the collect on an interval for an in-progress run.
- Before claiming agent behavior, capture `launchctl print gui/$(id -u)/io.goodkind.celltunnel-agent`, `Products/celltunnelctl status`, and `log show --predicate 'subsystem == "io.goodkind.celltunnel"' --info --last 30s`.
- Before claiming relay discovery or selection behavior, capture `Products/celltunnelctl devices` and the selected relay endpoint.
- Before claiming route behavior, capture `route -n get` for each tested IPv4 and IPv6 destination, `ifconfig` for the active `utun` interface, and `netstat -ibn` counters before and after traffic.
- Before any route-mutating test, use narrow `AllowedIPs` host routes. Do not test broad default routes until a scoped IPv4 and IPv6 proof passes and the user has explicitly approved the broader swap.
- Before claiming traffic uses cellular, capture iPhone-side evidence showing `interface: pdp_ip0` and `uses cell`, plus app logs showing `cellular wireguard udp` send and receive activity. A successful Mac `curl` alone is not cellular proof.
- After a failed or interrupted route test, run `Products/celltunnelctl stop`, verify `Products/celltunnelctl status` reports `running=false`, and verify the scoped routes no longer point at the old `utun` interface before retrying.

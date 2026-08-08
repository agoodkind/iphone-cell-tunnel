# Running the app in a virtual machine

Run the Mac Catalyst app, the agent, and an iPhone simulator together in an isolated macOS virtual machine, building on the host and running only the apps inside the machine. The machine cannot build this project, so the split is what makes the isolation practical.

Isolation matters because these runs launch the app, drive its windows, and install a VPN profile. Doing that on the host takes over the desktop and changes the host's own routing.

## What a machine run covers

A machine run covers the agent, the command-line tool, the Mac app's screens and status words, the configuration library, and every flow that does not need a connected iPhone. That includes importing and activating configurations, resetting, and reading status.

The iPhone simulator hosts the same relay runtime the on-device packet tunnel hosts, so the control link, the forwarder, and the status path are real rather than stubbed. Only the background tunnel host is absent, which a foreground app does not need.

## What a machine run does not cover

Nothing that needs a physical iPhone, because the simulator carries the relay runtime but
not a cellular modem. Measuring what a real cellular link does belongs on hardware.

Pairing, routing, and traffic all work in a machine once local network access is granted
to both the agent and the phone app. Until that is granted the agent binds its control
port and reports its listener ready while publishing no record, so a browse sees nothing
and `celltunnelctl peers` reports none found. `docs/machine.md` names that approval and
the two others a tunnel needs.

## Entitlements in a machine

The agent writes the configuration library to the data-protection keychain, which requires the process to carry a team-prefixed application identifier. macOS grants that through an embedded provisioning profile, and a development profile authorizes it only on a machine registered to the account. A machine is not registered, so a development-signed agent is otherwise killed at launch with `OS_REASON_CODESIGNING`.

Setting a boot argument that stops entitlement enforcement removes that limit, which is acceptable because the machine is disposable. System Integrity Protection is already off in the base image, which is what allows the argument to be set at all, but turning it off does not by itself stop the entitlement check.

```sh
ssh admin@<ip> 'echo admin | sudo -S nvram boot-args="amfi_get_out_of_my_way=1"'
ssh admin@<ip> 'echo admin | sudo -S shutdown -r now'
```

Confirm it applied with `nvram boot-args` after the machine comes back. With the argument in place a development-signed agent bootstraps and stays running, and importing a configuration succeeds where it previously failed with keychain status `-34018`.

## Why the machine does not build

Building inside the machine fails at two separate points, so do not spend time on it.

The dev tool needs the generated configuration constants, and the step that generates them compiles the dev tool first. That circle only breaks on a host that has already generated them. Project generation also reaches the network for dependency updates, which the machine does not have.

Building from the shared folder fails earlier still, because the compiler cannot complete its index-store writes there.

## Prepare and run the machine

One command does the whole sequence: it confirms the machine is ready, builds every
target signed, verifies each signature, transfers the products, runs the agent under
launchd, launches the phone app in a simulator, and waits for the two to pair.

```sh
swift Tools/cell-tunnel-dev.swift mac <host> Debug
```

Running it again against the same machine replaces what it installed, so a rerun needs no
cleanup first.

What that machine needs and why is in [machine.md](machine.md): which image carries
Xcode, how to fetch it quickly, which products are copied in and how to tell a stale one,
the boot argument that lets a development-signed agent run, the approvals a tunnel cannot
start without, and how to read logs there.

## Run the Catalyst app and the tests

```sh
tart exec <your-clone> open -a /Users/admin/ict/Debug-maccatalyst/CellTunnelPhone.app
```

The UI tests run through the dev tool's `ui-test` command, which takes one target and needs no make flow:

```sh
swift Tools/cell-tunnel-dev.swift ui-test mac-catalyst
swift Tools/cell-tunnel-dev.swift ui-test iphone-simulator
```

The command generates the project, applies the same signing override a signed build relies on, resolves the destination, and runs only the `CellTunnelPhoneUITests` suite. For the simulator target it also picks a phone simulator and boots it first. That suite is one cross-platform target built for both iPhone and Mac Catalyst. `Tests/CellTunnelPhoneUITests/CellTunnelPhoneUITests.swift` covers the status screen, its scrolling, and the config library, and `Tests/CellTunnelPhoneUITests/VPNProfileDisabledUITests.swift` covers the switched-off VPN profile screen.

The tests drive a fixture rather than a live agent. `Apps/iOS/Testing/UITestFixture.swift` is a `#if DEBUG` backend the app substitutes when a launch argument such as `--cell-tunnel-ui-test-fixture` or `--cell-tunnel-ui-test-vpn-disabled` is present, so a run needs no phone, no agent, and no saved VPN profile. `Tools/CellTunnelDevTests/UITestCommandContractTests.swift` pins that boundary: it asserts the fixture stays behind `#if DEBUG` and never reaches `AgentClient`, `ServiceManagement`, the app group, or the device egress probe, and it asserts the `ui-test` command, the cross-platform test target, and the accessibility identifiers the tests tap all still exist.

Run the command on the host, not in the machine. It compiles the app and the test bundle as part of the run, and the machine does not build. Running the tests inside the machine instead would need a test bundle and an `.xctestrun` test plan that a normal build does not produce, plus rewriting the absolute host paths the plan records, since those paths are what let the machine find the app and the test bundle.

Write test output to a file and copy it back over the network, since `tart exec` output is not always captured.

## Clean up

Stop and delete your clone when the run finishes, so clones do not accumulate.

```sh
tart stop <your-clone>
tart delete <your-clone>
```

Delete any `vm-products` directory left in the worktree. It is ignored by git, which matters because staging a WireGuard configuration there puts a private key one `git add` away from a commit. Prefer `/tmp` for any archive you stage by hand.

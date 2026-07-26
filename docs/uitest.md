# Running the app in a virtual machine

Run the Mac Catalyst app, the agent, and an iPhone simulator together in an isolated macOS virtual machine, building on the host and running only the apps inside the machine. The machine cannot build this project, so the split is what makes the isolation practical.

Isolation matters because these runs launch the app, drive its windows, and install a VPN profile. Doing that on the host takes over the desktop and changes the host's own routing.

## What a machine run covers

A machine run covers the agent, the command-line tool, the Mac app's screens and status words, the configuration library, and every flow that does not need a connected iPhone. That includes importing and activating configurations, resetting, and reading status.

The iPhone simulator hosts the same relay runtime the on-device packet tunnel hosts, so the control link, the forwarder, and the status path are real rather than stubbed. Only the background tunnel host is absent, which a foreground app does not need.

## What a machine run does not cover

Peer discovery does not work in a headless machine, so nothing that needs a connected iPhone can run there. That rules out starting the tunnel, and therefore also the saved VPN profile, routing, and traffic counters.

The failure is specific. During the pairing window the agent binds its control port and reports the listener ready, and both `sudo lsof` and `netstat` confirm a socket listening on that port. The Bonjour record for `_cellrelaycontrol._tcp` is never published: a `dns-sd` browse on the same machine inside the same window sees nothing, while a generic browse in that same machine sees every other service on the network. The iPhone app's browser therefore never receives the advertisement and `celltunnelctl peers` reports no peers found. The same build discovers the peer within seconds on a machine where local network access has already been granted.

Anything needing a connected iPhone belongs on a machine where that access exists.

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

## Prepare the machine

Clone the base machine under your own name before starting it. Another agent may be using the shared one, and two runs on the same machine collide.

```sh
tart clone ict-ui-test ict-live-$(date +%Y%m%d-%H%M%S)
tart run <your-clone> --no-graphics \
  --dir=celltunnel:/path/to/your/worktree \
  --dir=swift-makefile:/path/to/swift-makefile
```

Name each shared folder exactly as the package directory is named. The Swift package manager resolves a local dependency by folder name, so mounting swift-makefile under any other name fails with an unknown-package error.

The machine answers `tart ip` within seconds, but `tart exec` needs its guest agent, which takes about half a minute more. A connection error right after boot means the agent is still starting, so wait and retry.

The machine has no `timeout` command, so leave it out of any command you send. Bound long commands from the host instead.

Install a key and reuse one connection rather than repeating password logins. Repeated password logins exhaust the machine's authentication attempts and start failing with `Too many authentication failures`, which reads like a wrong password.

```sh
ssh-keygen -t ed25519 -N '' -f ~/.ssh/ict_guest
sshpass -p admin ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  admin@<ip> "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys" < ~/.ssh/ict_guest.pub
```

Record the machine in `~/.ssh/config` so every later `ssh` and `scp` picks up the key and the shared connection without repeating flags. The commands below assume this entry exists and refer to the machine as `ictguest`.

```
Host ictguest
  HostName <ip>
  User admin
  IdentityFile ~/.ssh/ict_guest
  IdentitiesOnly yes
  ControlMaster auto
  ControlPath /tmp/ict-ssh-%r@%h
  ControlPersist 300
```

Send anything longer than one command as a script file rather than inline, because nested quoting through `ssh` and `tart exec` silently changes predicates and swallows output. Write the script locally, copy it over, and run it with `bash`.

## Build on the host

Build each target you intend to run in the machine. The agent and its tunnel provider come from `mac`, the Mac app from `mac-catalyst`, and the iPhone app from `iphone-simulator`. Run them one at a time, because two builds in the same worktree collide on a locked build database. Each build leaves the other targets' products in place, so the three accumulate.

```sh
for target in mac mac-catalyst iphone-simulator; do
  SWIFT_MK_DEV_DIR=/path/to/swift-makefile \
  SWIFT_MK_REQUIRE_SIGNING=1 \
  SWIFT_MK_SIGN_IDENTITY="Apple Development" \
  SWIFT_MK_SIGN_TEAM=H3BMXM4W7H \
  SWIFT_MK_SIGN_STYLE=Automatic \
    swift Tools/cell-tunnel-dev.swift build "$target" Debug
done
```

Set the signing identity and team explicitly. The engine writes its signing override only when an identity or a team resolves, and with neither it writes nothing at all. The project already asks each signable target for automatic signing with an Apple Development identity, so what is missing in that case is the team, and the result is a bundle with no team identifier. `SWIFT_MK_REQUIRE_SIGNING` is not what turns signing on; it makes the build stop before compiling when no team resolves, which turns a silently unusable bundle into an early failure. Such a bundle cannot reach the keychain, and the failure surfaces only when something tries to store a configuration, as keychain status `-34018`.

Confirm the result rather than assuming it, because an unsigned bundle builds and launches normally and only fails later:

```sh
codesign -dv Products/Debug/CellTunnelAgent.app
```

`TeamIdentifier=H3BMXM4W7H` means it is signed. `Signature=adhoc` with `TeamIdentifier=not set` means it is not.

Signed products land under `Products/`, not under `build/DerivedData`. Only the macOS slice sits in `Products/Debug`; the other two carry a platform suffix, as `Products/Debug-maccatalyst` and `Products/Debug-iphonesimulator`.

Point `SWIFT_MK_DEV_DIR` at your local swift-makefile so the build resolves the engine from disk instead of fetching it.

If the build reports missing constants such as `agentBinaryName`, copy `Sources/CellTunnelCore/Generated/Config.generated.swift` from a checkout that has already generated it. The file is not tracked, so a fresh worktree lacks it.

If the build reports a precompiled file compiled with a different module cache path, delete `Tools/.build` and build again. A previous run inside the machine wrote that cache under the machine's own paths.

## Move the products into the machine

Copy over the network, not through the shared folder. Reading a large file from the shared mount fails partway with an input/output error and yields a file whose checksum differs from the source, which then presents as a corrupt archive or a broken signature rather than as a copy failure.

```sh
ditto -c -k --keepParent Products/Debug/CellTunnelAgent.app /tmp/agent.zip
ditto -c -k --keepParent Products/Debug-maccatalyst/CellTunnelPhone.app /tmp/catalyst.zip
ditto -c -k --keepParent Products/Debug-iphonesimulator/CellTunnelPhone.app /tmp/phone.zip
scp /tmp/agent.zip /tmp/catalyst.zip /tmp/phone.zip Products/celltunnelctl ictguest:
ssh ictguest 'set -e
mkdir -p ~/ict/Debug ~/ict/Debug-maccatalyst ~/ict/Debug-iphonesimulator
ditto -x -k ~/agent.zip ~/ict/Debug/
ditto -x -k ~/catalyst.zip ~/ict/Debug-maccatalyst/
ditto -x -k ~/phone.zip ~/ict/Debug-iphonesimulator/
chmod +x ~/celltunnelctl'
```

Copy `celltunnelctl` too. It is a separate product in `Products/`, not part of the agent bundle, so the transfer misses it otherwise and every later command fails with a missing file that reads like a broken agent.

Use an archive rather than a directory copy. A signed bundle copied with `rsync` arrives ad-hoc, because the copy drops the signature.

Verify the transfer before trusting it:

```sh
shasum -a 256 /tmp/agent.zip
tart exec <your-clone> shasum -a 256 /Users/admin/agent.zip
tart exec <your-clone> codesign -v --verbose=2 /Users/admin/ict/Debug/CellTunnelAgent.app
```

## Run the agent

The agent registers a Mach service, so it must run under launchd rather than by opening the app. The bundle ships its own `Contents/Library/LaunchAgents/agent-launchd.plist`, but that one uses `BundleProgram`, which only resolves when the app registers itself. Write a copy that names the binary by absolute path and keeps the same `MachServices` key.

```sh
ssh ictguest 'cat > ~/Library/LaunchAgents/io.goodkind.celltunnel-agent.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>io.goodkind.celltunnel-agent</string>
  <key>Program</key><string>/Users/admin/ict/Debug/CellTunnelAgent.app/Contents/MacOS/CellTunnelAgent</string>
  <key>MachServices</key><dict><key>io.goodkind.celltunnel-agent</key><true/></dict>
  <key>KeepAlive</key><true/>
</dict>
</plist>
PLIST
mkdir -p ~/Library/LaunchAgents
launchctl bootstrap gui/501 ~/Library/LaunchAgents/io.goodkind.celltunnel-agent.plist
launchctl print gui/501/io.goodkind.celltunnel-agent'
```

The service name must match `io.goodkind.celltunnel-agent`, because that is the Mach service the app looks up. After replacing the binary, restart it with `launchctl kickstart -k gui/501/io.goodkind.celltunnel-agent` rather than bootstrapping again.

`state = running` with a pid means it is up. `last exit reason = OS_REASON_CODESIGNING` means the entitlements are not authorized on this machine, which the boot argument above resolves.

Verify the agent answers before running anything against it:

```sh
ssh ictguest '~/celltunnelctl status'
```

A healthy agent prints the status block ending in `vpn_profile=absent` on a machine with no saved profile. Repeated `agent xpc session open failed` in the log means the Mach service is not registered, which happens when the app is opened directly instead of run under launchd.

## Run the iPhone simulator as the relay peer

```sh
tart exec <your-clone> xcrun simctl boot <device-udid>
tart exec <your-clone> xcrun simctl install <device-udid> /Users/admin/ict/Debug-iphonesimulator/CellTunnelPhone.app
tart exec <your-clone> xcrun simctl launch <device-udid> io.goodkind.CellTunnelPhone
```

Confirm the runtime started rather than assuming the process is enough:

```sh
ssh ictguest 'xcrun simctl spawn <device-udid> \
  log show --last 60s --predicate '"'"'subsystem CONTAINS "celltunnel"'"'"' --style compact'
```

Look for `relay runtime started` and the browse lines for `_cellrelaycontrol._tcp` and `_cellrelay._udp`. Those lines mean the phone side is healthy; they do not mean it will find the Mac, which is the discovery limit described above.

When checking Bonjour by hand, pass `dns-sd` a timeout. Without `-t` it runs until killed and its output can be lost entirely, which looks like an empty result rather than a still-running browse.

```sh
ssh ictguest 'dns-sd -t 12 -B _cellrelaycontrol._tcp local'
```

## Run the Catalyst app and the tests

```sh
tart exec <your-clone> open -a /Users/admin/ict/Debug-maccatalyst/CellTunnelPhone.app
```

Running the Catalyst UI tests in the machine needs a test bundle and an `.xctestrun` test plan, and the build above produces neither. That path is not documented here because it has not been run end to end since the build layout changed, and the obvious shortcuts are both wrong: the engine refuses a build-for-testing outside a gated make flow, and calling `xcodebuild` directly skips the signing override this page depends on, which lands you back at the keychain failure the signing section exists to prevent. Completing this section means finding the gated route, transferring the resulting products the same way as above, and rewriting the absolute host paths the test plan records, since those paths are what let the machine find the app and the test bundle.

Write test output to a file and copy it back over the network, since `tart exec` output is not always captured.

## Clean up

Stop and delete your clone when the run finishes, so clones do not accumulate.

```sh
tart stop <your-clone>
tart delete <your-clone>
```

Delete any `vm-products` directory left in the worktree. It is ignored by git, which matters because staging a WireGuard configuration there puts a private key one `git add` away from a commit. Prefer `/tmp` for the archives, as the transfer steps above do.

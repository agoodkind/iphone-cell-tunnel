# Running the app in a disposable machine

A tart virtual machine runs the Mac agent and an iPhone simulator together, so a pairing
and routing test exercises both sides without a physical phone. Products build on the
host and copy in; nothing compiles inside the machine.

## What the machine needs

Use an image that carries Xcode. The base macOS image has no `xcrun simctl`, so the
simulator that plays the phone cannot boot and the run stops there.
`ghcr.io/cirruslabs/macos-tahoe-xcode` supplies Xcode, `simctl`, and iOS runtimes.

Match the image's Xcode to the host's iOS simulator SDK. An app built against a newer
SDK than the machine's runtime will not install. Read the host's with
`xcodebuild -showsdks` and `xcrun simctl list runtimes`, and pick the image tag whose
Xcode carries that runtime build.

Allow roughly 160 GB of free space for the Xcode image, which is 68.5 GB compressed and
expands to a 140 GB disk occupying about 87 GB.

## Fetching an image quickly

`tart pull` from a remote registry runs at roughly nine megabits per second and its
`--concurrency` flag does not change that. Fetch the layers separately and serve them
back:

1. Ask `ghcr.io` for a pull token and fetch the manifest.
2. Download every layer by digest with `aria2c -j16 -x4 -s4 --file-allocation=none`.
   Mint a fresh token each round and loop until every layer is present, because a token
   expires long before a large image finishes and an expired one makes the downloader
   exit reporting success partway through.
3. Verify each file's sha256 against its digest. This is not optional. Layers arrive
   with the correct byte count and wrong contents, which a size check accepts and which
   surfaces later as a corrupt disk.
4. Serve the verified blobs as a read-only registry on localhost, which needs three
   endpoints: `/v2/` returning `{}`, the manifest with media type
   `application/vnd.oci.image.manifest.v1+json`, and each blob by digest.
5. Run `tart pull --insecure 127.0.0.1:<port>/cirruslabs/<image>:<tag>`, which completes
   in about a minute and lets tart do its own decompression and disk assembly.

Do not hand-assemble the disk image. tart decompresses Apple-framed LZ4 layers into a
sparse image at offsets derived from each layer's uncompressed-size annotation, and
serving a local registry gets the same result without reproducing that logic.

## Three approvals a tunnel needs

A machine created for a run has answered no prompts, so a tunnel cannot carry traffic
until each of these is granted. None are automated.

**Local network access for the agent.** Until granted, the agent binds its socket and
publishes no record, so the phone browses and finds nothing. The system log reports
`Local network access to reg_service policy 'pending'` and `nehelper` notes it is
showing an alert even though the app is not in the foreground.

**The VPN profile.** Before it exists, status reads `vpn_profile=absent` and the agent
logs `agent resolved tunnel manager count=0`, so routing intent turns on while the
tunnel stays down. Neither the agent nor `celltunnelctl` creates the profile. Launching
the Mac app raises the dialog that does.

**Local network access for the phone app.** Until granted, the relay link never comes
up, status holds `links=0`, and the log reports the same pending policy against the
phone's bundle identifier.

## Registering the packet tunnel extension

macOS registers app extensions from apps in `/Applications`, and the agent runs from the
directory the harness installs into, so the extension stays unregistered. The system
logs `Found 0 registrations for <provider bundle id>` and the tunnel cannot start.

Register it directly:

```
pluginkit -a <agent>.app/Contents/PlugIns/CellTunnelTunnelProvider.appex
```

Confirm with `pluginkit -m -v -i <provider bundle id>`. Its output carries the build
version, which also serves as the check that the loaded provider is the build under
test.

## Driving the machine's screen

Use Facebook's idb rather than clicking the machine's window. The companion must run
beside the simulator, so copy the host's installed companion directory into the machine;
it is self-contained and needs no package manager there. Run
`idb_companion --udid <device> --grpc-port 10882` in the machine, then
`idb connect <guest-ip> 10882` from the host.

That gives `idb screenshot`, `idb ui describe-all`, `idb ui tap`, `idb launch`, and
`idb terminate` over the network. Prefer tapping by accessibility label over
coordinates, which drift with device size. The accessibility tree is empty while the app
is not foreground, so relaunch and wait rather than concluding the bridge is broken.

A system permission alert appears in neither `idb ui describe-all` nor `idb screenshot`,
because those alerts belong to the system rather than the app.

Answering a macOS alert in the machine's window works by keyboard. Read the focus ring
in a screenshot taken immediately before pressing, since acting on a stale frame presses
the wrong button. Press Space to activate the focused button rather than Return, which
activates the default.

An iOS alert ignores Tab until Full Keyboard Access is on:

```
xcrun simctl spawn <device> defaults write com.apple.Accessibility FullKeyboardAccessEnabled -bool true
```

## Recovering a denied permission

A denial persists and blocks every later run. Resetting with `tccutil` and restarting
`mDNSResponder` and `nehelper` do not clear it. Rebooting the machine does, after which
the policy reads `pending` again and the prompt returns.

Never delete the `com.apple.networkextension` preferences domain to clear one app's
entry. That domain holds the VPN profile and every app's grant.

## Reading logs in a machine

Call `/usr/bin/log` by absolute path. `log` is a zsh builtin, so `log show` over a
remote shell runs the builtin and fails with `too many arguments`, and a following
`grep` consumes standard output while that error goes to standard error, which makes a
command that never ran look like an empty result.

Bound every browse. `dns-sd` without `-t` does not terminate over a non-interactive
session and can produce no output at all, which reads as an empty result rather than a
browse still running.

## Machine lifetime

The machine is disposable. Create it for a run and remove it afterwards, and keep its
storage off the boot volume, which lacks room for a macOS guest.

Start it as a long-lived background process. A `tart run` started from a shell command
stops when that shell exits, taking the window with it.

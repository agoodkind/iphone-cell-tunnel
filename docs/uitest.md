# Running the Catalyst UI tests in a virtual machine

Run the Mac Catalyst UI tests in an isolated macOS virtual machine by building on the host and running only the tests inside the machine. The machine cannot build this project, so the split is what makes the isolation practical.

Isolation matters because these tests launch the app and drive its windows. Running them on the host takes over the desktop and competes with anything else using it.

## Why the machine does not build

Building inside the machine fails at two separate points, so do not spend time on it.

The dev tool needs the generated configuration constants, and the step that generates them compiles the dev tool first. That circle only breaks on a host that has already generated them. Project generation also reaches the network for dependency updates, which the machine does not have.

Building from the shared folder fails earlier still, because the compiler cannot complete its index-store writes there.

## Prepare the machine

Clone the base machine under your own name before starting it. Another agent may be using the shared one, and two runs on the same machine collide.

```sh
tart clone ict-ui-test ict-ui-test-<yourname>
tart run ict-ui-test-<yourname> --no-graphics \
  --dir=celltunnel:/path/to/your/worktree \
  --dir=swift-makefile:/path/to/swift-makefile
```

Name each shared folder exactly as the package directory is named. The Swift package manager resolves a local dependency by folder name, so mounting swift-makefile under any other name fails with an unknown-package error.

The machine answers `tart ip` within seconds, but `tart exec` needs its guest agent, which takes about half a minute more. A connection error right after boot means the agent is still starting, so wait and retry.

Note that the machine has no `timeout` command, so leave it out of any command you send.

## Build on the host

```sh
SWIFT_MK_DEV_DIR=/path/to/swift-makefile \
  swift Tools/cell-tunnel-dev.swift build mac-catalyst Debug
```

Point `SWIFT_MK_DEV_DIR` at your local swift-makefile so the build resolves the engine from disk instead of fetching it.

If the build reports missing constants such as `agentBinaryName`, copy `Sources/CellTunnelCore/Generated/Config.generated.swift` from a checkout that has already generated it. The file is not tracked, so a fresh worktree lacks it.

If the build reports a precompiled file compiled with a different module cache path, delete `Tools/.build` and build again. A previous run inside the machine wrote that cache under the machine's own paths.

## Run the tests in the machine

Copy the built products into a directory inside the mounted worktree first. A newly built `build/DerivedData` has not reliably appeared through the shared folder, while a directory staged beside it does.

```sh
rsync -a build/DerivedData/Build/Products/ vm-products/
```

Then, inside the machine, copy those products to its own disk, point the test plan at the new location, and run the tests without building.

```sh
tart exec ict-ui-test-<yourname> bash -lc '
  rsync -a "/Volumes/My Shared Files/celltunnel/vm-products/" ~/ict-products/
  cd ~/ict-products
  sed -i "" "s|<host-products-path>|/Users/admin/ict-products|g" \
    CellTunnelPhone_macosx26.5-arm64.xctestrun
  xcodebuild test-without-building \
    -xctestrun CellTunnelPhone_macosx26.5-arm64.xctestrun \
    -destination "platform=macOS,variant=Mac Catalyst" \
    -only-testing:CellTunnelPhoneUITests'
```

The test plan records absolute host paths, so rewriting them is what lets the machine find the app and the test bundle.

Write test output to a file and copy it back through the shared folder, since `tart exec` output is not always captured.

## Clean up

Stop and delete your clone when the run finishes, so clones do not accumulate.

```sh
tart stop ict-ui-test-<yourname>
tart delete ict-ui-test-<yourname>
```

Also delete the staged `vm-products` directory from the worktree.

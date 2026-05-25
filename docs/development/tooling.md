# Tooling

The repository `Makefile` and `bootstrap.mk` are the canonical `swift-makefile` consumer
interface. The Makefile delegates project-specific work to
`swift Tools/cell-tunnel-dev.swift <command>`.

## Automation Ownership

- `bootstrap.mk` fetches `swift-makefile` assets into `.make/`.
- `.make/` is ignored build tooling state.
- `swift-makefile` owns shared lint, format, baseline, analyze, audit, update, and fetch policy.
- `SWIFT_MK_DEV_DIR` makes `bootstrap.mk` fetch from that local checkout before using the GitHub
  API or raw URL.
- `SWIFT_MK_SKIP_FETCH=1` makes `bootstrap.mk` reuse already fetched `.make/` assets.
- `Makefile` wires project-specific commands into `swift-makefile` variables.
- Project-specific `Makefile` targets call `swift Tools/cell-tunnel-dev.swift <command>`.
- `Tools/cell-tunnel-dev.swift` builds and delegates to the Swift tools package at
  `Tools/Package.swift`.
- `CellTunnelDev` owns protobuf and gRPC code generation, project generation, build, test, lint,
  audit, analyze, clean, signing, notarization, and run orchestration.
- Go automation runs through `make -C Daemon <target>` with `Daemon/bootstrap.mk`.
- Project-local shell scripts are not part of the tooling model.

## Typed IPC Generation

- `.proto` files under `Protos/` are the committed source of truth for control IPC.
- `make generate` regenerates Swift bindings into `Sources/CellTunnelCore/Generated/` and Go
  bindings into `Daemon/internal/controlv1/`.
- Swift control bindings are generated through the Swift-owned `CellTunnelDev` workflow and the
  SwiftPM `generate-grpc-code-from-protos` command plugin.
- Go control bindings are generated through the same Swift-owned workflow by invoking `protoc`
  with the Go gRPC plugins.

## Build Targets

`swift Tools/cell-tunnel-dev.swift build <target> [Debug|Release]` requires an explicit target.
Bare `build` prints the usage line and exits non-zero. The same guardrail applies to
`make build TARGET=<target>`; bare `make build` errors out.

Targets:

- `daemon` builds `celltunneld` and `celltunnelctl` only. This is the fast path for the sudo-run
  dev loop.
- `mac` builds daemon, ctl, and `CellTunnelMac.app` packaged and signed.
- `iphone-simulator` builds daemon, ctl, and the iOS simulator app.
- `iphone-device` builds daemon, ctl, and the iOS device app with codesign.
- `all` builds every target above.

Every target runs `generate`, `lintSwiftProject`, `lintGoProject`, `auditLogging`, and
`auditGoProject` before any compile. None of those can be skipped from the command line. The build
prints SHA256 fingerprints for `Products/celltunneld` and `Products/celltunnelctl` at the end. The
`mac` and `all` targets also fingerprint the daemon copy inside the freshly built app bundle and
the daemon installed at `/Applications/CellTunnelMac.app/Contents/Library/LaunchServices/celltunneld`.

If the wrapper output is piped through `tee`, read `${PIPESTATUS[0]}` instead of `$?` so the real
exit code is not masked.

## Activation Targets

`swift Tools/cell-tunnel-dev.swift activate <target> [Debug|Release]` installs, registers, and
launches a previously built target. The same target names appear on `make run`, `make install`, and
`make deploy`.

Activation targets:

- `mac` activates `CellTunnelMac.app` from the freshly built bundle and drives helper
  registration.
- `iphone` installs and launches the physical-device app on the connected iPhone.
- `iphone-simulator` reuses a booted iPhone simulator or creates and boots a fresh one before
  install and launch.

The activation target names differ from the build target names. The physical iPhone build target
is `iphone-device`. The matching activation target is `iphone`.

## Canonical Targets

```sh
make generate
make lint
make log-audit
make go-audit
make test
make analyze
make build TARGET=daemon
make build TARGET=mac
make build TARGET=iphone-simulator
make build TARGET=iphone-device
make build TARGET=all
make signing-check
make run TARGET=mac
make run TARGET=iphone
make run TARGET=iphone-simulator
make install TARGET=mac
make install TARGET=iphone
make install TARGET=iphone-simulator
make deploy TARGET=mac
make deploy TARGET=iphone
make deploy TARGET=iphone-simulator
make clean
```

## iPhone Log Viewing

`swift Tools/cell-tunnel-dev.swift iphone-logs` streams the iPhone syslog over USB via
`idevicesyslog`. Flags:

- `--app` filters to lines mentioning `CellTunnelPhone` or `io.goodkind.celltunnel`.
- `--simulator` streams `log stream` with a predicate on the `io.goodkind.celltunnel` subsystem on
  the Mac host log store. This catches simulator runs.
- `--device <udid>` pins to a specific iPhone when more than one is connected.

If `xcdevice list` returns no device, the auto-pick fails. Pass `--device <udid>` to bypass.

## Verification Contract

- After Swift app or tooling changes, run `make lint`, `make log-audit`, `make go-audit`,
  `make test`, `make analyze`, `make build TARGET=mac`, `make signing-check`, and
  `make run TARGET=mac`.
- After Go daemon changes, run `make lint`, `make go-audit`, `make test`, `make analyze`, and
  `make build TARGET=daemon`.
- After signing or notarization tooling changes, run `make signing-check`, `make notarize-check`,
  and `make notarize`.
- Before handoff, run
  `git -C /Users/agoodkind/Sites/iphone-cell-tunnel status --short --untracked-files=all`.
- Generated project, workspace, build, product, and Go tooling artifacts must not be tracked.

# Tooling

The repository `Makefile` and `bootstrap.mk` are the canonical `swift-makefile` consumer interface.

## Automation Ownership

- `bootstrap.mk` fetches `swift-makefile` assets into `.make/`.
- `.make/` is ignored build tooling state.
- `swift-makefile` owns shared lint, format, baseline, analyze, audit, update, and fetch policy.
- `SWIFT_MK_DEV_DIR` makes `bootstrap.mk` fetch from that local checkout before using the GitHub API or raw URL.
- `SWIFT_MK_SKIP_FETCH=1` makes `bootstrap.mk` reuse already fetched `.make/` assets.
- `Makefile` wires project-specific commands into `swift-makefile` variables.
- Project-specific `Makefile` targets call `swift Tools/cell-tunnel-dev.swift <command>`.
- `Tools/cell-tunnel-dev.swift` builds and delegates to the Swift tools package at `Tools/Package.swift`.
- `CellTunnelDev` owns protobuf and gRPC code generation, project generation, build, test, lint, audit, analyze,
  clean, signing, notarization, and run orchestration.
- Go automation runs through `make -C Daemon <target>` with `Daemon/bootstrap.mk`.
- Project-local shell scripts are not part of the tooling model.

## Typed IPC Generation

- `.proto` files under `Protos/` are the committed source of truth for control IPC.
- `make generate` regenerates Swift bindings into `Sources/CellTunnelCore/Generated/` and Go bindings into
  `Daemon/internal/controlv1/`.
- Swift control bindings are generated through the Swift-owned `CellTunnelDev` workflow and the SwiftPM
  `generate-grpc-code-from-protos` command plugin.
- Go control bindings are generated through the same Swift-owned workflow by invoking `protoc` with the Go gRPC
  plugins.

## Canonical Targets

```sh
make generate
make lint
make log-audit
make go-audit
make test
make analyze
make build
make signing-check
make run
make clean
```

`make build` runs the lint, Swift logging audit, Go audit, Go daemon build, macOS app build, iOS simulator app build,
Mac bundle packaging, and Mac signing path.

`make run` builds through the gated path and launches `CellTunnelMac` from `Products/Debug/macosx/CellTunnelMac.app`.

## Verification Contract

- After Swift app or tooling changes, run `make lint`, `make log-audit`, `make go-audit`, `make test`,
  `make analyze`, `make build`, `make signing-check`, and `make run`.
- After Go daemon changes, run `make lint`, `make go-audit`, `make test`, `make analyze`, and `make build`.
- After signing or notarization tooling changes, run `make signing-check`, `make notarize-check`, and `make notarize`.
- Before handoff, run `git -C /Users/agoodkind/Sites/iphone-cell-tunnel status --short --untracked-files=all`.
- Generated project, workspace, build, product, and Go tooling artifacts must not be tracked.

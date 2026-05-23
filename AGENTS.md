# Cell Tunnel Agent Rules

These rules are the source of truth for changes in this repository. Follow them before touching tunnel behavior, Swift app code, Go daemon code, or tooling.

## Evidence First

- Read this file, `README.md`, `Makefile`, `Tools/cell-tunnel-dev.swift`, `Project.swift`, `Package.swift`, and the relevant source before editing.
- Treat the current source, generated product paths, command output, and logs as evidence. Do not infer architecture from filenames alone.
- Use the repository `Makefile` as the canonical interface. Do not run ad hoc `xcodebuild`, `tuist`, Swift compiler, Go build, Go test, install, or app launch commands when a `make` target exists.
- Do not edit generated Xcode projects or workspaces as source of truth.

## Tooling Ownership

- All build, test, lint, audit, analyze, clean, and run orchestration must live in Swift under `Tools/`.
- The `Makefile` must stay a thin alias layer that calls `swift Tools/cell-tunnel-dev.swift <command>`.
- Project-local shell scripts are banned. Do not add committed `.sh` tooling, embedded shell programs, or shell-script fallbacks.
- The only allowed shell-bearing exception is the canonical `go-makefile` bootstrap path under `Daemon/bootstrap.mk` and generated `Daemon/.make/` assets, because the user explicitly wants Go tooling to stay current with `go-makefile`.
- Go and C-family code may implement runtime logic, but build tooling must remain Swift-owned.
- Generated outputs must remain ignored: `.build/`, `build/`, `Derived/`, `DerivedData/`, `Products/`, `.make/`, generated Xcode projects, and generated workspaces.

## Swift Standards

- Swift formatting is owned by `.swift-format` with 4-space indentation and 120-column preferred line length.
- SwiftLint runs with `opt_in_rules: all`, analyzer rules enabled, and strict mode.
- Do not add `swiftlint:disable` comments.
- Do not use `print`, `debugPrint`, `dump`, `NSLog`, direct `os_log`, direct `Logger(subsystem:)`, or ad hoc logger construction in runtime Swift.
- Runtime Swift must use `CellTunnelLog` only.
- Every Swift executable must bootstrap logging before app setup.
- Every runtime Swift file that owns logic must declare exactly one typed logger category unless the logging audit allowlist gives a reason.
- Every log interpolation must declare explicit privacy.
- Do not use `.warning`; use `.notice` for recoverable events and `.error` for failures.
- Preserve Swift concurrency correctness, typed state, narrow protocols, and clear app, UI, daemon, and domain boundaries.

## Logging Is P0

- Logging is required at every runtime boundary and every meaningful logic decision.
- Required boundaries include app lifecycle, command dispatch, user actions, state transitions, I/O, process execution, networking callbacks, listener state, peer accept/cancel/failure, frame decode, frame dispatch, route planning, environment checks, `catch`, and recovery paths.
- Error logs must include the operation, reason, and recovery decision when one exists.
- Logs must not expose secrets, tokens, private user data, or noisy high-cardinality payloads.
- `make log-audit` is the deterministic SwiftSyntax gate for runtime Swift logging.
- `make go-audit` is the deterministic Go gate for `vet`, `govulncheck`, `deadcode`, and the `go-makefile` AST analyzer set.

## Go Standards

- The Go daemon inherits strict standards from `/Users/agoodkind/Sites/go-makefile` through the canonical consumer bootstrap in `Daemon/bootstrap.mk`.
- The root Swift driver delegates Go targets to `make -C Daemon <target>` and sets `GO_MK_DEV_DIR` from `GO_MAKEFILE_DIR` or `~/Sites/go-makefile` when available, so local go-makefile changes are exercised before the published fetch path.
- `Daemon/Makefile` must stay a thin go-makefile consumer. Do not add local lint, deadcode, audit, fmt, vet, staticcheck, or baseline targets there.
- Go formatting, GolangCI, `gocyclo`, `deadcode`, `govulncheck`, and `staticcheck-extra` are owned by go-makefile.
- `//nolint` is banned in production Go. Fix the code or document an exception through a baseline process, not inline suppression.
- Direct diagnostic output is banned outside user-facing CLI output in `package main`; library code must use structured `log/slog`.
- Every Go process, command, external-call, route-planning, environment-check, state, and error boundary must emit structured `slog`.
- `slog.Error` calls must carry an `err` field.
- Do not use `any` or `interface{}` in production Go. Model closed domains with named types, structs, and enums.
- Do not switch over bare strings for closed command or state sets. Use named string types and constants.
- Do not call `os.Exit` outside `main`.
- Do not use `context.TODO`, `panic`, uncancelable sleeps, unbounded goroutines, no-op lifecycle methods, or silent close paths in production code.

## Verification Contract

- After Swift app or tooling changes, run `make lint`, `make log-audit`, `make go-audit`, `make test`, `make analyze`, `make build`, and `make run` unless the user explicitly narrows verification.
- After Go daemon changes, run `make lint`, `make go-audit`, `make test`, `make analyze`, and `make build`.
- `make build` must be gated by lint, Swift logging audit, and Go audit.
- `make run` must launch the macOS app from the canonical product path under `Products/`.
- Before reporting completion, run `git status --short --untracked-files=all` and confirm no generated project, workspace, or build artifact is tracked.
- If a required command cannot run, report the exact command and the exact reason.

# Engineering Rules

## Evidence

- Read `AGENTS.md`, `README.md`, `Makefile`, `Tools/cell-tunnel-dev.swift`, `Tools/CellTunnelDev/`, `Project.swift`,
  `Package.swift`, and the relevant source before editing.
- Treat source, command output, generated product paths, and logs as evidence.
- Do not infer architecture from filenames alone.
- Do not edit generated Xcode projects or workspaces as source of truth.

## Swift

- Swift formatting is owned by `.swift-format`.
- SwiftLint runs in strict mode with analyzer rules enabled.
- Do not add `swiftlint:disable` comments.
- Runtime Swift logs through `CellTunnelLog` only.
- Runtime Swift does not use `print`, `debugPrint`, `dump`, `NSLog`, direct `os_log`, direct `Logger(subsystem:)`, or
  ad hoc logger construction.
- Every Swift executable bootstraps logging before app setup.
- Every runtime Swift file with logic declares one typed logger category unless the logging audit allowlist contains a
  reason.
- Every Swift log interpolation declares explicit privacy.
- Runtime Swift uses `.notice` for recoverable events and `.error` for failures.
- Swift code preserves actor isolation, `Sendable` correctness, typed state, narrow protocols, and explicit boundaries.

## Go

- The Go daemon inherits lint and analyzer policy from the canonical `go-makefile` bootstrap in `Daemon/bootstrap.mk`.
- `Daemon/Makefile` stays a thin `go-makefile` consumer.
- Go runtime code logs through structured `log/slog`.
- Every Go process, command, external-call, route-planning, environment-check, state, and error boundary emits
  structured logs.
- `slog.Error` calls carry an `err` field.
- Production Go does not use `//nolint`, `any`, `interface{}`, `context.TODO`, `panic`, unbounded goroutines,
  uncancelable sleeps, no-op lifecycle methods, or silent close paths.
- Closed Go command and state sets use named types and constants.
- `os.Exit` is only allowed in `main`.

## Logging

- Logging is required at runtime boundaries and meaningful logic decisions.
- Required logging boundaries include app lifecycle, command dispatch, user actions, state transitions, I/O, networking
  callbacks, listener state, peer accept/cancel/failure, frame decode, frame dispatch, route planning, environment
  checks, `catch`, and recovery paths.
- Error logs include the operation, reason, and recovery decision when a recovery decision exists.
- Logs do not expose secrets, tokens, private user data, packet payloads, key material, or high-cardinality byte content.

## Runtime Boundaries

- App behavior, daemon behavior, helper registration, UI presentation, route mutation, and protocol framing stay in
  separate ownership boundaries.
- Platform-specific behavior stays behind the boundary that owns that platform.
- Runtime behavior is implemented in real start, stop, relay, and route paths, not only in previews, tests, dry-run
  output, or fallback code.

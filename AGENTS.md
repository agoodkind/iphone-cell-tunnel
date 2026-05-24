# Cell Tunnel Agent Entry Point

Read these documents before editing this repository:

- [Architecture](docs/architecture/mvp-wireguard-relay.md)
- [Engineering Rules](docs/development/engineering-rules.md)
- [Tooling](docs/development/tooling.md)
- [Signing](docs/development/signing.md)
- [MVP Device Check](docs/runbooks/mvp-device-check.md)
- [MVP CLI Check](docs/runbooks/mvp-cli-check.md)

General rules:

- Use the committed `Makefile` and `bootstrap.mk` as the canonical `swift-makefile` consumer interface.
- Use `swift-makefile` for shared lint, format, baseline, analyze, audit, update, and fetch policy.
- Use `SWIFT_MK_DEV_DIR` from the shell environment to fetch `swift-makefile` assets from a local checkout.
- Keep project-specific build, generation, test execution, device, signing, notarization, packaging, and run workflows in Swift under `Tools/`.
- Wire project-specific Swift workflows into `swift-makefile` variables instead of duplicating shared targets.
- Do not add committed project-local shell scripts.
- Do not edit generated Xcode projects, generated workspaces, build output, product output, or generated Go tooling.
- Keep secrets, private keys, certificates, WireGuard private keys, P12 passwords, and notary credentials out of Git, logs, and chat.
- Do not weaken lint, audit, analyzer, signing, or verification gates to pass a handoff.

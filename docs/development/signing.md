# Signing

The Mac build signs two products: the `CellTunnelAgent` command-line tool and the `CellTunnelTunnelProvider` Network Extension app extension. `make build TARGET=mac` signs both through Xcode automatic signing.

## Identity

Signing uses an `Apple Development` certificate for the configured team under automatic signing (`CODE_SIGN_STYLE = Automatic`). The team comes from `TUIST_DEVELOPMENT_TEAM` or `DEVELOPMENT_TEAM`, with the default in `Tools/CellTunnelDev/Support.swift`. `config/signing.env` supplies overrides and is ignored by Git. Provisioning profiles auto-create with `-allowProvisioningUpdates`.

On an `Apple Development` certificate the value in the CN parentheses is a Team Member ID, not the Team ID; the real Team ID is the certificate `OU` field and matches the `TeamIdentifier` recorded on the signed product.

## Entitlements

Both Mac products carry `com.apple.developer.networking.networkextension = [packet-tunnel-provider]` and `com.apple.security.application-groups = [group.io.goodkind.CellTunnel]`, declared in `Apps/macOS/Entitlements/Agent.entitlements` and `Apps/macOS/Entitlements/TunnelProvider.entitlements`.

## Verification

Signed paths are verified with `codesign --verify --strict`. Nested frameworks and dylibs are signed before any bundle that contains them.

## Secrets

- P12 passwords, `.p8` contents, API key IDs, API issuer IDs, WireGuard private keys, and certificate private keys stay outside committed files.
- Tool output and chat output refer to secret-bearing material by path or environment variable name only.

## Distribution

`make notary-setup`, `make notarize-check`, and `make notarize` drive notarization through `Tools/CellTunnelDev/Signing.swift`. That path signs and notarizes a Mac `.app` bundle and predates the agent-plus-extension layout, so it requires rework before the current products can be notarized and distributed.

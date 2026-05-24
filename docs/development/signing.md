# Signing

Mac signing is mandatory for build and run targets.

## Identity

The default signing identity is:

```text
Developer ID Application: Alex Goodkind (H3BMXM4W7H)
```

`config/signing.env` may override signing values. `config/signing.env` is ignored by Git.

The Swift driver resolves duplicate Developer ID common names to a concrete keychain identity hash before invoking
`codesign`.

## Bundle Signing

- The Go daemon is signed as `io.goodkind.celltunneld`.
- The daemon copy inside `CellTunnelMac.app` is signed as `io.goodkind.celltunneld`.
- Nested frameworks and dylibs are signed before the app bundle.
- `CellTunnelMac.app` is signed as `io.goodkind.CellTunnelMac`.
- Hardened runtime and secure timestamps are required.
- Every signed path is verified with `codesign --verify --strict`.

## Secrets

- P12 passwords, `.p8` contents, API key IDs, API issuer IDs, WireGuard private keys, and certificate private keys stay
  outside committed files.
- Tool output and chat output must refer to secret-bearing material by path or environment variable name only.

## Distribution Targets

The Swift driver owns these distribution targets:

```sh
make notary-setup
make notarize-check
make notarize
```

`make notarize` builds through the gated path, archives the signed macOS app, submits with `notarytool --wait`, staples
the accepted ticket, validates the staple, and runs Gatekeeper assessment with `spctl`.

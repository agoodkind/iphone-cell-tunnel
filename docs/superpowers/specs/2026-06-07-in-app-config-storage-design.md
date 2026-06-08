# In-app config storage and editing

## Problem

Loading a WireGuard config into the relay today means putting a `.conf` file on
disk and pointing the CLI at it with `relay-up --config <path>`. On the Desktop
that path is TCC-protected, so it turns into a full-disk-access dance. The Mac
Catalyst app has no way to load or hold a config itself.

## Goal

Let the Mac Catalyst app import, store, name, edit, and activate WireGuard
configs in-app, so the relay starts and reloads from a config the app holds, with
no file-on-disk or full-disk step.

## Decisions (locked)

- Platform: Mac Catalyst only. The WireGuard config is the Mac client's; the
  iPhone carries none.
- Storage: a named library of configs in the app keychain (app-private).
- On import: store the config and apply it immediately.
- Editing: a raw SwiftUI text editor with the `PrivateKey` value masked by
  default and a reveal toggle. The config text is never written to the log.
- Apply an edit: reload in place over the existing reload path, no restart.
- Parsing and validation: the agent owns them. The app does not parse and does
  not link `WireGuardKit`. It hands the config to the agent over XPC, and the
  agent validates on apply and returns any error the UI surfaces. The masking
  helper is a pure line scan, no parser.

## What already exists

- `AgentRelayBackend.installTunnel(configURL:)` (`Apps/iOS/Services/AgentRelayBackend.swift`)
  reads a security-scoped URL, copies the bytes into the shared app-group
  container (`group.io.goodkind.CellTunnel`) as `imported-tunnel.conf`, and calls
  `client.startTunnel(TunnelStartSettings(wireGuardConfigPath:))`. The agent reads
  the container path, which is not TCC-protected. The TCC dance is already solved
  for the app path; there is no UI that calls it.
- `AgentClient.startTunnel` and `AgentClient.reloadTunnel` (`Sources/CellTunnelCore/AgentClient.swift`)
  send a config path to the agent over the shared libxpc transport. `reloadTunnel`
  applies an edited config to the running tunnel in place
  (`AgentTunnelController+Reload.swift`), with no restart or VPN profile save.
- The agent stores the active config text in the saved VPN profile
  `providerConfiguration["wireguardConfig"]` and the extension reads it back
  (`PacketTunnelProvider.extractWireGuardConfigText`).

The wire path: validation sends the full config text to the agent over the libxpc
transport, the one new XPC payload. Applying keeps the existing hand-off, where the
app writes the active config to the shared app-group file and calls `startTunnel`
or `reloadTunnel` with that path. The apply path is unchanged, so
`TunnelStartSettings` is untouched.

## Architecture

### TunnelConfigStore (new, Mac Catalyst)

Owns the named library. Backed by the app keychain (app-private, no shared access
group, since the agent never reads the keychain). Responsibilities:

- `list() -> [StoredConfig]`: every stored config, ordered by name.
- `add(name:text:) -> StoredConfig`: validate the text with the WireGuard parser,
  then store. Reject invalid text with the parser's error.
- `update(id:text:)`: re-validate and replace the text.
- `rename(id:name:)` and `delete(id:)`.
- `activeID` and `setActive(id:)`: which config the relay uses.

`StoredConfig`: `id` (UUID string), `name`, `text` (raw wg-quick), `createdAt`.
The keychain entry is one generic-password item per config, the config text as
the secret value, the id as the account, and a small JSON of metadata; the active
id is one more keychain item. The text holds the `PrivateKey`, so it lives in the
keychain, never in `UserDefaults` or a plist.

### Validation (agent answers yes or no over XPC)

The app does no WireGuard parsing and does not link `WireGuardKit`. The Catalyst
app links only `CellTunnelCore` and `CellTunnelLog`, and that stays true. The agent
validates: the app sends the config text to the agent over the existing libxpc
transport and the agent replies valid or invalid with a message, without starting
a tunnel. The UI shows that result, then stores and applies only a valid config.

To answer without a running tunnel, the agent parses the text itself. The existing
`WireGuardConfigParser` and the `AddressPrefix` and `AddressFamily` types move from
the provider target into `CellTunnelCore` and become public, so both the agent and
the extension link them through `CellTunnelCore`. The provider's builder and route
set import them from there. A new `validateConfig(text:)` request in the agent
control protocol calls the parser and returns ok or a failure message; `AgentClient`
gains the matching call. The masking helper is a pure line scan in `CellTunnelCore`
that finds the `PrivateKey` line by prefix, so it needs no parser.

### Backend additions

`RelayControlBackend` gains config-library operations, implemented only in
`AgentRelayBackend` (Mac), no-op or absent on the iPhone and simulator backends:

- `importConfig(url:name:)`: read under security scope, send the text to
  `validateConfig`; on valid, `store.add`, set active, write to the app-group file,
  and `startTunnel` with that path; on invalid, surface the message and store nothing.
- `activateConfig(id:)`: write that config to the app-group file, `startTunnel`.
- `saveConfigEdit(id:text:)`: `validateConfig`; on valid, `store.update`, and if it
  is the active config and the relay is running, write to the app-group file and
  `reloadTunnel`.
- `renameConfig`, `deleteConfig`, `listConfigs`.

Validation sends the text over XPC; applying reuses the existing
`copyConfigIntoSharedContainer` app-group hand-off, so the apply path is unchanged.

### UI (new SwiftUI, Mac Catalyst)

A Configs card on the Mac screen plus an editor sheet.

```
┌─ Configs ───────────────────────────────┐
│  home-scoped            ● active   ✎  ⋯  │
│  full-tunnel                       ✎  ⋯  │
│  work-lab                          ✎  ⋯  │
│                                          │
│  [ + Import .conf ]                      │
└──────────────────────────────────────────┘

⋯ menu: Activate · Rename · Delete

✎ opens the editor:

┌─ Edit: home-scoped ──────────────────────┐
│ PrivateKey   ••••••••••••••  [ Reveal ] │
│ Address = 10.250.10.8/32, ...            │
│ PublicKey = abc123...                    │
│ AllowedIPs = 2620:fe::fe/128, ...        │
│ Endpoint = home.goodkind.io:51820        │
│                                          │
│            [ Cancel ]   [ Save ]         │
└──────────────────────────────────────────┘
```

- Import uses `UIDocumentPickerViewController` for `.conf` and plain text.
- The active config shows a marker; only one is active.
- The editor binds to the raw text. The `PrivateKey` value is masked and that
  line is locked until Reveal. Save validates with the WireGuard parser and
  surfaces a parse error inline.
- The card and editor are Mac-only, behind `#if targetEnvironment(macCatalyst)`,
  consistent with the existing backend split.

## Security

- The config text, which contains the `PrivateKey`, is stored only in the
  keychain.
- The `PrivateKey` value is masked in the editor by default and is never logged.
- For validation the config text crosses only the local libxpc transport as the
  request payload.
- Applying writes the active config to the app-group file as the agent hand-off,
  the existing behavior, and the agent stores it in its VPN profile where a
  NetworkExtension WireGuard config must live.

## Validation and edge cases

- Invalid config is caught by the agent on apply, which returns a failure the UI
  surfaces. On import the config is stored, then applied; if apply fails it stays
  stored but not running, with the error shown.
- An empty library shows only the Import button.
- Editing a non-active config stores it and changes no relay state.
- Deleting the active config clears the active marker and leaves the running
  relay as is until another config is activated.
- Duplicate names are allowed. The id is the key, so two configs may share a
  name; the list shows both.

## Testing

- `TunnelConfigStore`: add, update, rename, delete, set active, and a keychain
  round-trip, using a test keychain or an injected store protocol.
- The `PrivateKey` masking helper: a config with and without a `PrivateKey` line,
  multi-line interface sections, and reveal round-trip.
- Parser reuse: a valid wg-quick config parses, an invalid one throws the
  expected error.
- The XPC `startTunnel` and `reloadTunnel` paths are unchanged and already
  covered.

## Out of scope

- iPhone config UI. The iPhone carries no WireGuard config.
- Changing the parser's logic. It moves to `CellTunnelCore` unchanged and stays
  the single parser the agent and extension share.
- QR import, key generation, and on-demand SSID rules from the WireGuard app.
- iCloud or cross-device sync of the library.

## Files likely touched

- New: `Apps/iOS/Services/TunnelConfigStore.swift` (Mac), the Configs SwiftUI
  views, and the masking helper.
- Edit: `Apps/iOS/Services/AgentRelayBackend.swift` (library operations),
  `RelayControlBackend` protocol, the Mac screen model to surface the card.
- Move `WireGuardConfigParser`, `AddressPrefix`, and `AddressFamily` from
  `Apps/macOS/TunnelProvider/Runtime/` into `Sources/CellTunnelCore/`, made public,
  and update the provider's builder and route set to import them from core.
- Add a `validateConfig(text:)` case to the agent control request, an `AgentClient`
  method, and an agent handler that parses and returns ok or a failure message.
- No fork or WireGuardKit changes in the app: the Catalyst app does not link
  WireGuardKit.
- Entitlements unchanged: app-group already present; the keychain is app-private.

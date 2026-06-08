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
- Parsing: reuse WireGuard's wg-quick parser and serializer from the
  `agoodkind/wireguard-apple` fork over `WireGuardKit`'s `TunnelConfiguration`.
  Do not hand-roll a second parser in the app.

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

So the wire path is unchanged: the app writes the active config to the app-group
file and calls `startTunnel` or `reloadTunnel` with that path. No new XPC field.

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

### Parser reuse

Expose WireGuard's wg-quick parser as a consumable product from the fork so the
app links it, rather than copying it. The fork
(`agoodkind/wireguard-apple`) ships only the `WireGuardKit` product today; the
parser (`Sources/Shared/Model/TunnelConfiguration+WgQuickConfig.swift`, with
`String+ArrayConversion.swift`) is app-target source. The plan adds a small
library product in the fork that exposes the parser over `WireGuardKit`'s
`TunnelConfiguration`. Fallback if the fork change is deferred: vendor those two
files into a `CellTunnelCore` submodule. The app uses this to validate on
import and save and to find the `PrivateKey` line for masking. The agent keeps
its own `WireGuardConfigParser` for now; migrating the agent onto the shared
parser is a separate follow-up, out of scope here.

### Backend additions

`RelayControlBackend` gains config-library operations, implemented only in
`AgentRelayBackend` (Mac), no-op or absent on the iPhone and simulator backends:

- `importConfig(url:name:)`: read under security scope, `store.add`, set active,
  write to the app-group file, `startTunnel`.
- `activateConfig(id:)`: write that config to the app-group file, `startTunnel`.
- `saveConfigEdit(id:text:)`: `store.update`; if it is the active config and the
  relay is running, write to the app-group file and `reloadTunnel`.
- `renameConfig`, `deleteConfig`, `listConfigs`.

The existing `copyConfigIntoSharedContainer` helper is reused as the one place a
config text reaches the agent.

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
- The app-group `imported-tunnel.conf` holds the active config in plaintext only
  as the agent hand-off. This is the existing behavior, not new.

## Validation and edge cases

- Invalid config on import or save is rejected with the WireGuard parser's error,
  shown inline. Nothing is stored or sent.
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
- Migrating the agent off its own `WireGuardConfigParser` onto the shared parser.
- QR import, key generation, and on-demand SSID rules from the WireGuard app.
- iCloud or cross-device sync of the library.

## Files likely touched

- New: `Apps/iOS/Services/TunnelConfigStore.swift` (Mac), the Configs SwiftUI
  views, and the masking helper.
- Edit: `Apps/iOS/Services/AgentRelayBackend.swift` (library operations),
  `RelayControlBackend` protocol, the Mac screen model to surface the card.
- Fork: `agoodkind/wireguard-apple` Package to expose the wg-quick parser
  product, plus this repo's `Tuist/Package.swift` to consume it.
- Entitlements unchanged: app-group already present; the keychain is app-private.

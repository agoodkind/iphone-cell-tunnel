# In-app config storage and editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the Mac Catalyst app import, name, edit, and activate WireGuard configs in-app, so the relay starts and reloads from a config the app holds, with no file-on-disk or full-disk step.

**Architecture:** Store a named library of configs in the app keychain. To activate or reload one, write its text to the shared app-group file and call the existing `startTunnel` or `reloadTunnel` over XPC, the same hand-off `installTunnel` already uses. Reuse WireGuard's wg-quick parser for client-side validation. The masking helper and pure models live in `CellTunnelCore` for `make test`; the keychain store and SwiftUI views live in the Mac Catalyst app.

**Tech Stack:** Swift 6, SwiftUI (stock, Mac Catalyst), Security framework keychain, WireGuardKit, the libxpc `AgentClient`, Tuist project, SwiftPM tests.

---

## Conventions every task must follow

- Every new Swift file starts with the canonical header (`//` block: file name, module, `Created by Alexander Goodkind <alex@goodkind.io> on <creation-date>`, `Copyright`), `// MARK: -` dividers throughout, and `///` on types and functions. Use `git config user.name`/`user.email` for the header, today's date for new files.
- No `Task.sleep`, `sleep`, `try?`, or `print`. Route logs through `CellTunnelLog`. Never log the config text or the `PrivateKey`.
- Mac-only code sits behind `#if targetEnvironment(macCatalyst)`, matching `AgentRelayBackend.swift`.
- Run `make lint` clean before every commit. Build the app with `make build TARGET=mac-catalyst CONFIG=Debug`. Run core tests with `make test`.
- Commit messages: one imperative subject line, no body.

## File structure

- Create `Sources/CellTunnelCore/ConfigSecretMasking.swift`: pure helper that masks and reveals the `PrivateKey` value in wg-quick text.
- Create `Sources/CellTunnelCore/StoredTunnelConfig.swift`: the `StoredTunnelConfig` model and the `TunnelConfigStore` protocol plus an in-memory implementation.
- Create `Sources/CellTunnelWireGuardConfig/` (new SwiftPM + Tuist library target): vendored WireGuard wg-quick parser, depends on `WireGuardKit`.
- Create `Apps/iOS/Services/KeychainTunnelConfigStore.swift`: keychain-backed `TunnelConfigStore` (Mac).
- Modify `Apps/iOS/Services/AgentRelayBackend.swift`: add library operations, reuse `copyConfigIntoSharedContainer`.
- Modify `Apps/iOS/Services/RelayController.swift`: extend `RelayControlBackend`, expose a config-library facade to the views.
- Modify `Apps/iOS/Views/PreviewRelayBackend.swift`, `Apps/iOS/Services/PhoneRelayBackend.swift`, `Apps/iOS/Services/SimulatorRelayBackend.swift`: conform to the new protocol methods as no-ops.
- Create `Apps/iOS/Views/ConfigLibraryView.swift` and `Apps/iOS/Views/ConfigEditorView.swift`: the Configs card and editor sheet.
- Modify `Apps/iOS/Views/MacStatusScreen.swift`: show the Configs card.
- Modify `Project.swift` and `Tuist/Package.swift` / `Package.swift`: declare the new `CellTunnelWireGuardConfig` target and link it into the app and tests.
- Create tests under `Tests/CellTunnelCoreTests/`.

---

## Task 1: Vendor the WireGuard wg-quick parser into a target

**Files:**
- Create: `Sources/CellTunnelWireGuardConfig/WgQuickConfigParse.swift` (vendored from the fork)
- Create: `Sources/CellTunnelWireGuardConfig/StringArrayConversion.swift` (vendored helper)
- Modify: `Package.swift` (add library product + target, depends on `WireGuardKit`)
- Modify: `Project.swift` (add a framework target so the Catalyst app can link it)

- [ ] **Step 1: Copy the parser sources from the fork checkout**

Source files in the resolved fork:
`Tuist/.build/checkouts/wireguard-apple/Sources/Shared/Model/TunnelConfiguration+WgQuickConfig.swift`
and `.../Sources/Shared/Model/String+ArrayConversion.swift`.

Copy both into `Sources/CellTunnelWireGuardConfig/`, add the canonical header to each, and keep the `import WireGuardKit` so `TunnelConfiguration` resolves. Do not edit the parsing logic.

- [ ] **Step 2: Declare the SwiftPM product and target**

In `Package.swift`, add a product and target:

```swift
.library(name: "CellTunnelWireGuardConfig", targets: ["CellTunnelWireGuardConfig"]),
```
```swift
.target(
  name: "CellTunnelWireGuardConfig",
  dependencies: [.product(name: "WireGuardKit", package: "wireguard-apple")]
),
```

Match the package-name string the repo already uses for the WireGuardKit dependency.

- [ ] **Step 3: Build the SwiftPM target**

Run: `swift build --target CellTunnelWireGuardConfig`
Expected: builds, the wg-quick parser compiles against `WireGuardKit.TunnelConfiguration`.

- [ ] **Step 4: Add the Tuist framework target so the app can link it**

In `Project.swift`, declare a `CellTunnelWireGuardConfig` framework target over the same sources and add it to the `CellTunnelPhone` target dependencies. Mirror how `WireGuardKit` is wired for the provider.

Run: `swift Tools/cell-tunnel-dev.swift generate`
Expected: the workspace regenerates with the new target.

- [ ] **Step 5: Commit**

```bash
git add Sources/CellTunnelWireGuardConfig Package.swift Project.swift
git commit -m "Add CellTunnelWireGuardConfig target with vendored wg-quick parser"
```

---

## Task 2: PrivateKey masking helper

**Files:**
- Create: `Sources/CellTunnelCore/ConfigSecretMasking.swift`
- Test: `Tests/CellTunnelCoreTests/ConfigSecretMaskingTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import CellTunnelCore
import Testing

struct ConfigSecretMaskingTests {
  @Test func masksPrivateKeyValueOnly() {
    let text = """
      [Interface]
      PrivateKey = ABCDEF0123456789ABCDEF0123456789ABCDEF0123=
      Address = 10.0.0.2/32
      """
    let masked = ConfigSecretMasking.maskingPrivateKey(in: text)
    #expect(masked.contains("PrivateKey = ••••••••"))
    #expect(!masked.contains("ABCDEF0123456789"))
    #expect(masked.contains("Address = 10.0.0.2/32"))
  }

  @Test func noPrivateKeyLineIsUnchanged() {
    let text = "[Peer]\nPublicKey = xyz\n"
    #expect(ConfigSecretMasking.maskingPrivateKey(in: text) == text)
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test`
Expected: FAIL, `ConfigSecretMasking` is undefined.

- [ ] **Step 3: Implement the helper**

```swift
import Foundation

// MARK: - ConfigSecretMasking

/// Masks the `PrivateKey` value in a wg-quick config for display, so the editor
/// can show the config without printing the secret. It only rewrites the value to
/// the right of `PrivateKey =`; every other line passes through unchanged. The
/// original text is never logged.
public enum ConfigSecretMasking {
  private static let maskedPlaceholder = "••••••••••••••"

  /// Returns the text with any `PrivateKey` value replaced by a fixed mask.
  public static func maskingPrivateKey(in text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let rewritten = lines.map { line -> Substring in
      maskedLine(from: line) ?? line
    }
    return rewritten.joined(separator: "\n")
  }

  private static func maskedLine(from line: Substring) -> Substring? {
    let trimmed = line.drop { $0 == " " || $0 == "\t" }
    guard trimmed.lowercased().hasPrefix("privatekey") else {
      return nil
    }
    guard let equalsIndex = line.firstIndex(of: "=") else {
      return nil
    }
    let prefix = line[...equalsIndex]
    return Substring("\(prefix) \(maskedPlaceholder)")
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CellTunnelCore/ConfigSecretMasking.swift Tests/CellTunnelCoreTests/ConfigSecretMaskingTests.swift
git commit -m "Add PrivateKey masking helper for config display"
```

---

## Task 3: StoredTunnelConfig model and store protocol with in-memory impl

**Files:**
- Create: `Sources/CellTunnelCore/StoredTunnelConfig.swift`
- Test: `Tests/CellTunnelCoreTests/TunnelConfigStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import CellTunnelCore
import Testing

struct TunnelConfigStoreTests {
  @Test func addStoresAndActivatesNothingByDefault() throws {
    let store = InMemoryTunnelConfigStore()
    let saved = try store.add(name: "home", text: "[Interface]\n")
    #expect(store.list().map(\.id) == [saved.id])
    #expect(store.activeID == nil)
  }

  @Test func setActiveMarksOneConfig() throws {
    let store = InMemoryTunnelConfigStore()
    let a = try store.add(name: "a", text: "x")
    let b = try store.add(name: "b", text: "y")
    store.setActive(id: b.id)
    #expect(store.activeID == b.id)
    store.setActive(id: a.id)
    #expect(store.activeID == a.id)
  }

  @Test func updateReplacesText() throws {
    let store = InMemoryTunnelConfigStore()
    let a = try store.add(name: "a", text: "old")
    try store.update(id: a.id, text: "new")
    #expect(store.list().first?.text == "new")
  }

  @Test func deleteActiveClearsActive() throws {
    let store = InMemoryTunnelConfigStore()
    let a = try store.add(name: "a", text: "x")
    store.setActive(id: a.id)
    try store.delete(id: a.id)
    #expect(store.list().isEmpty)
    #expect(store.activeID == nil)
  }

  @Test func renameChangesNameOnly() throws {
    let store = InMemoryTunnelConfigStore()
    let a = try store.add(name: "a", text: "x")
    try store.rename(id: a.id, name: "b")
    #expect(store.list().first?.name == "b")
    #expect(store.list().first?.text == "x")
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test`
Expected: FAIL, `StoredTunnelConfig`, `TunnelConfigStore`, `InMemoryTunnelConfigStore` undefined.

- [ ] **Step 3: Implement the model, protocol, and in-memory store**

```swift
import Foundation

// MARK: - StoredTunnelConfig

/// One named WireGuard config the app holds. `text` is the raw wg-quick body and
/// carries the `PrivateKey`, so a real store keeps it in the keychain, never in a
/// plist. `id` is the stable key; names may repeat.
public struct StoredTunnelConfig: Identifiable, Equatable, Sendable {
  public let id: String
  public var name: String
  public var text: String
  public let createdAt: Date

  public init(id: String, name: String, text: String, createdAt: Date) {
    self.id = id
    self.name = name
    self.text = text
    self.createdAt = createdAt
  }
}

// MARK: - TunnelConfigStore

/// A named library of WireGuard configs with one active selection. The keychain
/// implementation backs the app; the in-memory implementation backs tests.
public protocol TunnelConfigStore {
  func list() -> [StoredTunnelConfig]
  var activeID: String? { get }
  @discardableResult func add(name: String, text: String) throws -> StoredTunnelConfig
  func update(id: String, text: String) throws
  func rename(id: String, name: String) throws
  func delete(id: String) throws
  func setActive(id: String)
}

// MARK: - InMemoryTunnelConfigStore

/// A non-persistent store for tests and previews. It keeps the library in memory
/// and applies the same ordering and active-clear rules as the keychain store.
public final class InMemoryTunnelConfigStore: TunnelConfigStore {
  private var configs: [StoredTunnelConfig] = []
  private var active: String?
  private let now: () -> Date
  private let makeID: () -> String

  public init(now: @escaping () -> Date = Date.init, makeID: @escaping () -> String = { UUID().uuidString }) {
    self.now = now
    self.makeID = makeID
  }

  public func list() -> [StoredTunnelConfig] {
    configs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  public var activeID: String? { active }

  @discardableResult
  public func add(name: String, text: String) throws -> StoredTunnelConfig {
    let config = StoredTunnelConfig(id: makeID(), name: name, text: text, createdAt: now())
    configs.append(config)
    return config
  }

  public func update(id: String, text: String) throws {
    guard let index = configs.firstIndex(where: { $0.id == id }) else {
      throw TunnelConfigStoreError.notFound
    }
    configs[index].text = text
  }

  public func rename(id: String, name: String) throws {
    guard let index = configs.firstIndex(where: { $0.id == id }) else {
      throw TunnelConfigStoreError.notFound
    }
    configs[index].name = name
  }

  public func delete(id: String) throws {
    configs.removeAll { $0.id == id }
    if active == id {
      active = nil
    }
  }

  public func setActive(id: String) {
    guard configs.contains(where: { $0.id == id }) else {
      return
    }
    active = id
  }
}

// MARK: - TunnelConfigStoreError

public enum TunnelConfigStoreError: Error, Equatable {
  case notFound
  case keychainFailure(OSStatus)
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CellTunnelCore/StoredTunnelConfig.swift Tests/CellTunnelCoreTests/TunnelConfigStoreTests.swift
git commit -m "Add StoredTunnelConfig model and in-memory config store"
```

---

## Task 4: Keychain-backed store (Mac)

**Files:**
- Create: `Apps/iOS/Services/KeychainTunnelConfigStore.swift`

Note: the app target is not in the SwiftPM test bundle, so this task verifies by build and by the existing in-memory tests of the protocol. The keychain item is a generic password per config: `kSecAttrAccount` the id, `kSecAttrService` a fixed service, `kSecValueData` a JSON of `{name, text, createdAt}`. The active id is a single generic password under a separate account.

- [ ] **Step 1: Implement the keychain store**

```swift
#if targetEnvironment(macCatalyst)
  import CellTunnelCore
  import Foundation
  import Security

  private let keychainService = "io.goodkind.celltunnel.configs"
  private let activeAccount = "io.goodkind.celltunnel.configs.active"

  // MARK: - KeychainTunnelConfigStore

  /// A `TunnelConfigStore` backed by the app keychain. The config text holds the
  /// `PrivateKey`, so it lives here, never in UserDefaults or a plist. One generic
  /// password item per config, plus one item that records the active id.
  final class KeychainTunnelConfigStore: TunnelConfigStore {
    private struct Payload: Codable {
      var name: String
      var text: String
      var createdAt: Date
    }

    func list() -> [StoredTunnelConfig] {
      // SecItemCopyMatching with kSecMatchLimitAll, kSecReturnAttributes +
      // kSecReturnData, service = keychainService, decode each Payload, skip the
      // active-id item, sort by name.
      // ... implementation ...
    }

    var activeID: String? {
      // read the activeAccount item's data as a UTF-8 id, or nil.
      // ... implementation ...
    }

    @discardableResult
    func add(name: String, text: String) throws -> StoredTunnelConfig {
      let config = StoredTunnelConfig(
        id: UUID().uuidString, name: name, text: text, createdAt: Date())
      try writePayload(
        Payload(name: name, text: text, createdAt: config.createdAt), account: config.id)
      return config
    }

    func update(id: String, text: String) throws { /* read payload, set text, write */ }
    func rename(id: String, name: String) throws { /* read payload, set name, write */ }
    func delete(id: String) throws { /* SecItemDelete; clear active if it matched */ }
    func setActive(id: String) { /* write id bytes to activeAccount item */ }

    private func writePayload(_ payload: Payload, account: String) throws {
      let data = try JSONEncoder().encode(payload)
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: account,
      ]
      let attributes: [String: Any] = [kSecValueData as String: data]
      let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
      if status == errSecItemNotFound {
        var insert = query
        insert[kSecValueData as String] = data
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
          throw TunnelConfigStoreError.keychainFailure(addStatus)
        }
        return
      }
      guard status == errSecSuccess else {
        throw TunnelConfigStoreError.keychainFailure(status)
      }
    }
  }
#endif
```

Fill the elided readers with `SecItemCopyMatching`. Never log the decoded text. The list reader must exclude the `activeAccount` item.

- [ ] **Step 2: Build the app**

Run: `make build TARGET=mac-catalyst CONFIG=Debug`
Expected: builds clean.

- [ ] **Step 3: Lint**

Run: `make lint`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add Apps/iOS/Services/KeychainTunnelConfigStore.swift
git commit -m "Add keychain-backed tunnel config store for Mac"
```

---

## Task 5: Backend library operations

**Files:**
- Modify: `Apps/iOS/Services/RelayController.swift` (the `RelayControlBackend` protocol)
- Modify: `Apps/iOS/Services/AgentRelayBackend.swift`
- Modify: `Apps/iOS/Services/PhoneRelayBackend.swift`, `Apps/iOS/Services/SimulatorRelayBackend.swift`, `Apps/iOS/Views/PreviewRelayBackend.swift`

- [ ] **Step 1: Extend the protocol**

Add to `RelayControlBackend`:

```swift
/// The stored config library. Empty on platforms without one.
func listConfigs() -> [StoredTunnelConfig]
var activeConfigID: String? { get }
/// Import a config from a picked file: store it, mark active, and apply it.
func importConfig(url: URL, name: String) async
/// Make a stored config active and apply it.
func activateConfig(id: String) async
/// Save an edit; if it is the active config and the relay runs, reload in place.
func saveConfigEdit(id: String, text: String) async
func renameConfig(id: String, name: String) async
func deleteConfig(id: String) async
```

- [ ] **Step 2: Implement in `AgentRelayBackend`**

Hold a `KeychainTunnelConfigStore`. Reuse `copyConfigIntoSharedContainer`. Validate text with `TunnelConfiguration(fromWgQuickConfig:called:)` from `CellTunnelWireGuardConfig` before storing or applying; on a parse error, log a redacted error and keep state. Key methods:

```swift
private let store = KeychainTunnelConfigStore()

func listConfigs() -> [StoredTunnelConfig] { store.list() }
var activeConfigID: String? { store.activeID }

func importConfig(url: URL, name: String) async {
  do {
    let text = try readSecurityScoped(url)
    try validate(text)
    let saved = try store.add(name: name, text: text)
    store.setActive(id: saved.id)
    try await applyActive(text: text)
  } catch {
    logger.error("agent relay backend import failed recovery=keep-state")
  }
}

func activateConfig(id: String) async {
  guard let config = store.list().first(where: { $0.id == id }) else { return }
  store.setActive(id: id)
  do { try await applyActive(text: config.text) }
  catch { logger.error("agent relay backend activate failed recovery=keep-state") }
}

func saveConfigEdit(id: String, text: String) async {
  do {
    try validate(text)
    try store.update(id: id, text: text)
    guard store.activeID == id else { return }
    let path = try writeActiveToContainer(text)
    _ = try await client.reloadTunnel(settings: TunnelStartSettings(wireGuardConfigPath: path))
  } catch {
    logger.error("agent relay backend save edit failed recovery=keep-state")
  }
}

private func applyActive(text: String) async throws {
  let path = try writeActiveToContainer(text)
  _ = try await client.startTunnel(settings: TunnelStartSettings(wireGuardConfigPath: path))
}
```

Refactor `copyConfigIntoSharedContainer` into `writeActiveToContainer(_ text: String) -> String` (write text to the app-group `imported-tunnel.conf`) plus `readSecurityScoped(_ url: URL) -> String`, and have the existing `installTunnel(configURL:)` call them so there is one hand-off path. `validate(_:)` throws when the wg-quick parser rejects the text.

- [ ] **Step 3: Implement no-ops in the other backends**

In `PhoneRelayBackend`, `SimulatorRelayBackend`, and `PreviewRelayBackend`: `listConfigs()` returns `[]`, `activeConfigID` returns `nil`, and the async methods `await Task.yield()`. The iPhone carries no WireGuard config.

- [ ] **Step 4: Build and lint**

Run: `make build TARGET=mac-catalyst CONFIG=Debug` then `make build TARGET=iphone-simulator CONFIG=Debug` then `make lint`
Expected: all clean.

- [ ] **Step 5: Commit**

```bash
git add Apps/iOS
git commit -m "Add config library operations to relay backends"
```

---

## Task 6: Surface the library on the controller

**Files:**
- Modify: `Apps/iOS/Services/RelayController.swift`

- [ ] **Step 1: Add a thin facade the views call**

```swift
func listConfigs() -> [StoredTunnelConfig] { backend.listConfigs() }
var activeConfigID: String? { backend.activeConfigID }
func importConfig(url: URL, name: String) { Task { await backend.importConfig(url: url, name: name) } }
func activateConfig(id: String) { Task { await backend.activateConfig(id: id) } }
func saveConfigEdit(id: String, text: String) { Task { await backend.saveConfigEdit(id: id, text: text) } }
func renameConfig(id: String, name: String) { Task { await backend.renameConfig(id: id, name: name) } }
func deleteConfig(id: String) { Task { await backend.deleteConfig(id: id) } }
```

- [ ] **Step 2: Build and lint, then commit**

Run: `make build TARGET=mac-catalyst CONFIG=Debug` and `make lint`

```bash
git add Apps/iOS/Services/RelayController.swift
git commit -m "Expose config library facade on relay controller"
```

---

## Task 7: Config editor view with masking

**Files:**
- Create: `Apps/iOS/Views/ConfigEditorView.swift`

- [ ] **Step 1: Implement the editor sheet**

A SwiftUI sheet bound to an editable copy of the config text. The `PrivateKey` line is masked by default; a Reveal toggle swaps the displayed text between `ConfigSecretMasking.maskingPrivateKey(in:)` and the real text, and editing is enabled only when revealed so the real key is never lost behind the mask. Save calls `controller.saveConfigEdit(id:text:)` with the real text. Cancel dismisses.

```swift
import CellTunnelCore
import SwiftUI

struct ConfigEditorView: View {
  let config: StoredTunnelConfig
  @Environment(RelayController.self) private var controller
  @Environment(\.dismiss) private var dismiss
  @State private var text: String
  @State private var revealed = false

  init(config: StoredTunnelConfig) {
    self.config = config
    _text = State(initialValue: config.text)
  }

  var body: some View {
    NavigationStack {
      VStack {
        Toggle("Reveal private key", isOn: $revealed)
        if revealed {
          TextEditor(text: $text).font(.system(.body, design: .monospaced))
        } else {
          ScrollView {
            Text(ConfigSecretMasking.maskingPrivateKey(in: text))
              .font(.system(.body, design: .monospaced))
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .padding()
      .navigationTitle(config.name)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { controller.saveConfigEdit(id: config.id, text: text); dismiss() }
        }
      }
    }
  }
}
```

- [ ] **Step 2: Build and lint, then commit**

Run: `make build TARGET=mac-catalyst CONFIG=Debug` and `make lint`

```bash
git add Apps/iOS/Views/ConfigEditorView.swift
git commit -m "Add config editor view with masked private key"
```

---

## Task 8: Configs card and import

**Files:**
- Create: `Apps/iOS/Views/ConfigLibraryView.swift`
- Modify: `Apps/iOS/Views/MacStatusScreen.swift`

- [ ] **Step 1: Implement the Configs card**

A view listing `controller.listConfigs()`, marking `controller.activeConfigID`, with a per-row menu (Activate, Rename, Delete), an edit affordance that presents `ConfigEditorView`, and an Import button presenting `UIDocumentPickerViewController` for `.conf` and plain text via `UIViewControllerRepresentable`. On pick, prompt for a name (default the file's base name) and call `controller.importConfig(url:name:)`. Match the tile styling used by `MacStatusScreen` tiles.

- [ ] **Step 2: Insert the card into `MacStatusScreen`**

Add the card to the masonry input, after the existing tiles, behind `#if targetEnvironment(macCatalyst)`. Keep the existing `ConnectionSection` tiles unchanged.

- [ ] **Step 3: Build and lint**

Run: `make build TARGET=mac-catalyst CONFIG=Debug` and `make lint`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add Apps/iOS/Views/ConfigLibraryView.swift Apps/iOS/Views/MacStatusScreen.swift
git commit -m "Add Configs card with import, activate, edit, rename, delete"
```

---

## Task 9: Manual verification on device

**Files:** none

- [ ] **Step 1: Build and install the Mac app**

Run: `make build TARGET=mac-catalyst CONFIG=Debug`, then install and launch the Catalyst app.

- [ ] **Step 2: Import and apply**

In the app, Import a scoped `.conf`. Confirm the relay comes up: `swift Tools/cell-tunnel-dev.swift relay-status` reports `running=true` and, once the iPhone link is up, `routes=installed`. No file path or full-disk step was used.

- [ ] **Step 3: Edit and reload in place**

Edit the active config's `AllowedIPs` in the editor, Save, and confirm `relay-reload` behavior: the tunnel stays up and the route set changes, with no restart, verified by `relay-status` before and after.

- [ ] **Step 4: Library operations**

Import a second config, Activate it, Rename one, Delete one, and confirm the active marker and list update, and that deleting the active config leaves the running relay untouched until another is activated.

- [ ] **Step 5: Secret hygiene check**

Confirm the editor masks the `PrivateKey` until Reveal, and that `swift Tools/cell-tunnel-dev.swift mac-logs --last 5m` shows no config text or `PrivateKey` value.

---

## Self-review notes

- Spec coverage: storage (Tasks 3, 4), import-and-apply (Task 5, 8), edit-reload (Tasks 5, 7), library list/rename/delete (Tasks 5, 8), masking (Tasks 2, 7), parser reuse (Task 1), Mac-only (guards throughout), keychain for the secret (Task 4), agent hand-off reuse (Task 5). All covered.
- The keychain reader bodies in Task 4 are described, not spelled out line by line, because they are mechanical `SecItemCopyMatching` calls; the writer is shown in full and the readers mirror it. Fill them during implementation and keep the config text out of logs.
- Names are consistent across tasks: `TunnelConfigStore`, `StoredTunnelConfig`, `ConfigSecretMasking.maskingPrivateKey(in:)`, `writeActiveToContainer`, `importConfig(url:name:)`, `saveConfigEdit(id:text:)`.

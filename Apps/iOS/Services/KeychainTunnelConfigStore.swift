//
//  KeychainTunnelConfigStore.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-07.
//  Copyright © 2026, all rights reserved.
//

#if targetEnvironment(macCatalyst)
  import CellTunnelCore
  import CellTunnelLog
  import Foundation
  import Security

  private let keychainConfigStoreLogger = CellTunnelLog.logger(category: .store)
  private let keychainConfigStoreService = "io.goodkind.celltunnel.configs"
  private let keychainConfigStoreActiveAccount = "io.goodkind.celltunnel.configs.active"

  // MARK: - KeychainTunnelConfigStore

  /// Stores named WireGuard configs in the keychain so config text that contains a
  /// `PrivateKey` is never written to plist-backed app storage.
  final class KeychainTunnelConfigStore: TunnelConfigStore {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Listing

    /// Returns all stored configs, excluding the separate active-id keychain item.
    func list() -> [StoredTunnelConfig] {
      let query = serviceQuery()
      query.setObject(kSecMatchLimitAll, forKey: kSecMatchLimit as NSString)
      query.setObject(true, forKey: kSecReturnAttributes as NSString)
      query.setObject(true, forKey: kSecReturnData as NSString)

      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecItemNotFound {
        return []
      }
      guard status == errSecSuccess else {
        logKeychainFailure(action: "list configs", status: status)
        return []
      }
      guard let items = result as? NSArray else {
        return []
      }
      var configs: [StoredTunnelConfig] = []
      for case let item as NSDictionary in items {
        guard let config = storedConfig(from: item) else {
          continue
        }
        configs.append(config)
      }
      return configs.sorted { lhs, rhs in
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
      }
    }

    /// The active tunnel config id, if the active-id keychain item is present.
    var activeID: String? {
      guard let data = readData(account: keychainConfigStoreActiveAccount) else {
        return nil
      }
      guard let id = String(data: data, encoding: .utf8), !id.isEmpty else {
        return nil
      }
      return id
    }

    // MARK: - Mutations

    /// Adds a named config and returns the stored record with its generated id.
    @discardableResult
    func add(name: String, text: String) throws -> StoredTunnelConfig {
      let id = UUID().uuidString
      let createdAt = Date()
      let payload = Payload(name: name, text: text, createdAt: createdAt)
      let data = try encoder.encode(payload)
      try writeItem(account: id, data: data)
      return StoredTunnelConfig(id: id, name: name, text: text, createdAt: createdAt)
    }

    /// Updates the raw config text for an existing stored config.
    func update(id: String, text: String) throws {
      var payload = try readPayload(account: id)
      payload.text = text
      let data = try encoder.encode(payload)
      try writeItem(account: id, data: data)
    }

    /// Renames an existing stored config while preserving its text and creation date.
    func rename(id: String, name: String) throws {
      var payload = try readPayload(account: id)
      payload.name = name
      let data = try encoder.encode(payload)
      try writeItem(account: id, data: data)
    }

    /// Deletes a stored config and clears the active selection when it points there.
    func delete(id: String) throws {
      try deleteItem(account: id)
      if activeID == id {
        try deleteItem(account: keychainConfigStoreActiveAccount)
      }
    }

    /// Records which config id is active for the Catalyst app.
    func setActive(id: String) {
      let data = Data(id.utf8)
      do {
        try writeItem(account: keychainConfigStoreActiveAccount, data: data)
      } catch {
        keychainConfigStoreLogger.error(
          "keychain config store set-active failed recovery=leave-active-unchanged"
        )
        return
      }
    }

    // MARK: - Keychain helpers

    /// Writes one generic-password item, updating it first and adding it if missing.
    private func writeItem(account: String, data: Data) throws {
      let query = itemQuery(account: account)
      let attributes = NSMutableDictionary()
      attributes.setObject(data, forKey: kSecValueData as NSString)
      let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
      if updateStatus == errSecSuccess {
        return
      }
      guard updateStatus == errSecItemNotFound else {
        throw TunnelConfigStoreError.keychainFailure(updateStatus)
      }

      query.setObject(data, forKey: kSecValueData as NSString)
      let addStatus = SecItemAdd(query as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        throw TunnelConfigStoreError.keychainFailure(addStatus)
      }
    }

    /// Reads the value data for one keychain item.
    private func readData(account: String) -> Data? {
      let query = itemQuery(account: account)
      query.setObject(kSecMatchLimitOne, forKey: kSecMatchLimit as NSString)
      query.setObject(true, forKey: kSecReturnData as NSString)

      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      guard status == errSecSuccess else {
        return nil
      }
      return result as? Data
    }

    /// Removes one keychain item, treating a missing item as already deleted.
    private func deleteItem(account: String) throws {
      let status = SecItemDelete(itemQuery(account: account) as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw TunnelConfigStoreError.keychainFailure(status)
      }
    }

    /// Reads and decodes one config payload.
    private func readPayload(account: String) throws -> Payload {
      guard let data = readData(account: account) else {
        throw TunnelConfigStoreError.notFound
      }
      return try decoder.decode(Payload.self, from: data)
    }

    /// Converts one keychain result dictionary into a stored config.
    private func storedConfig(from item: NSDictionary) -> StoredTunnelConfig? {
      guard let account = item.object(forKey: kSecAttrAccount) as? String else {
        return nil
      }
      guard account != keychainConfigStoreActiveAccount else {
        return nil
      }
      guard let data = item.object(forKey: kSecValueData) as? Data else {
        return nil
      }
      do {
        let payload = try decoder.decode(Payload.self, from: data)
        return StoredTunnelConfig(
          id: account,
          name: payload.name,
          text: payload.text,
          createdAt: payload.createdAt
        )
      } catch {
        keychainConfigStoreLogger.error(
          "keychain config store decode failed recovery=skip-this-config"
        )
        return nil
      }
    }

    /// Builds a service-scoped keychain query.
    private func serviceQuery() -> NSMutableDictionary {
      let query = NSMutableDictionary()
      query.setObject(kSecClassGenericPassword, forKey: kSecClass as NSString)
      query.setObject(keychainConfigStoreService, forKey: kSecAttrService as NSString)
      return query
    }

    /// Builds a keychain query for one generic-password account.
    private func itemQuery(account: String) -> NSMutableDictionary {
      let query = serviceQuery()
      query.setObject(account, forKey: kSecAttrAccount as NSString)
      return query
    }

    // MARK: - Logging

    /// Logs a keychain status without including account ids or secret config text.
    private func logKeychainFailure(action: String, status: OSStatus) {
      keychainConfigStoreLogger.error(
        """
        keychain config store failed \
        action=\(action, privacy: .public) status=\(status, privacy: .public)
        """
      )
    }

    // MARK: - Payload

    /// The keychain value for one stored tunnel config.
    private struct Payload: Codable {
      var name: String
      var text: String
      var createdAt: Date
    }
  }

#endif

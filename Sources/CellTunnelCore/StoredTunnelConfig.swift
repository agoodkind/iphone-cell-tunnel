//
//  StoredTunnelConfig.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-07.
//  Copyright © 2026, all rights reserved.
//

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

  /// The text-free summary of this config, safe to cross the status snapshot
  /// because it carries no `PrivateKey`.
  public var summary: TunnelConfigSummary {
    TunnelConfigSummary(id: id, name: name, createdAt: createdAt)
  }
}

// MARK: - TunnelConfigSummary

/// The metadata of one stored config without its secret text, so the agent can
/// publish the library on the status snapshot without ever exposing a
/// `PrivateKey`. The full text crosses only on explicit import, save-edit, or a
/// dedicated text fetch.
public struct TunnelConfigSummary: Identifiable, Equatable, Codable, Sendable {
  public let id: String
  public var name: String
  public let createdAt: Date

  public init(id: String, name: String, createdAt: Date) {
    self.id = id
    self.name = name
    self.createdAt = createdAt
  }
}

// MARK: - TunnelConfigStore

/// A named library of WireGuard configs with one active selection. The keychain
/// implementation backs the agent; the in-memory implementation backs tests.
public protocol TunnelConfigStore {
  func list() -> [StoredTunnelConfig]

  var activeID: String? { get }

  @discardableResult func add(name: String, text: String) throws -> StoredTunnelConfig
  func update(id: String, text: String) throws
  func rename(id: String, name: String) throws
  func delete(id: String) throws
  func setActive(id: String)
}

// MARK: - TunnelConfigStore conveniences

/// Derived reads and a content-dedupe add, given once for every store so the
/// agent builds summaries, looks up text by id, and avoids duplicate entries
/// without each store reimplementing the logic.
extension TunnelConfigStore {
  /// The text-free summaries of every stored config, in list order.
  public func summaries() -> [TunnelConfigSummary] {
    list().map(\.summary)
  }

  /// The first stored config whose text matches exactly, the dedupe key. Internal,
  /// so the public helpers below use it without the extension reading as one
  /// uniform-access block.
  func firstMatchingText(_ text: String) -> StoredTunnelConfig? {
    list().first { $0.text == text }
  }

  /// The text of the stored config with this id, or `nil` when none matches.
  public func text(forID id: String) -> String? {
    list().first { $0.id == id }?.text
  }

  /// Reuses the existing entry when one already holds this exact text, otherwise
  /// adds a new one, so re-running the same config never makes a duplicate.
  @discardableResult
  public func addDeduplicated(name: String, text: String) throws -> StoredTunnelConfig {
    if let existing = firstMatchingText(text) {
      return existing
    }
    return try add(name: name, text: text)
  }

  /// Registers the currently-running config when the store does not already hold
  /// it, marking it active, so a tunnel started outside the app still appears in
  /// the library. A store that already holds the text only ensures an active id.
  @discardableResult
  public func reconcileRunning(text: String, nameIfNew: String) throws -> StoredTunnelConfig {
    if let existing = firstMatchingText(text) {
      if activeID == nil {
        setActive(id: existing.id)
      }
      return existing
    }
    let saved = try add(name: nameIfNew, text: text)
    setActive(id: saved.id)
    return saved
  }
}

// MARK: - InMemoryTunnelConfigStore

/// A non-persistent store for tests and previews. It keeps the library in memory
/// and applies the same ordering and active-clear rules as the keychain store.
public final class InMemoryTunnelConfigStore: TunnelConfigStore {
  private var configs: [StoredTunnelConfig] = []
  private var active: String?
  private let now: () -> Date
  private let makeID: () -> String

  public init(
    now: @escaping () -> Date = Date.init, makeID: @escaping () -> String = { UUID().uuidString }
  ) {
    self.now = now
    self.makeID = makeID
  }

  public func list() -> [StoredTunnelConfig] {
    configs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  public var activeID: String? { active }

  @discardableResult
  public func add(name: String, text: String) -> StoredTunnelConfig {
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

  public func delete(id: String) {
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
  case keychainFailure(OSStatus)
  case notFound
}

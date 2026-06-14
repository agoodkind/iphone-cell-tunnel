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
/// plist. `id` is the stable `UUID` key; names may repeat. Boundaries that need a
/// string (keychain account, NEVPN plist value, JSON wire, CLI argument) use
/// `id.uuidString`.
public struct StoredTunnelConfig: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var text: String
  public let createdAt: Date

  public init(id: UUID, name: String, text: String, createdAt: Date) {
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
/// dedicated text fetch. `UUID` encodes as a string over the JSON wire.
public struct TunnelConfigSummary: Identifiable, Equatable, Codable, Sendable {
  public let id: UUID
  public var name: String
  public let createdAt: Date

  public init(id: UUID, name: String, createdAt: Date) {
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

  var activeID: UUID? { get }

  @discardableResult func add(name: String, text: String) throws -> StoredTunnelConfig
  func update(id: UUID, text: String) throws
  func rename(id: UUID, name: String) throws
  func delete(id: UUID) throws
  func setActive(id: UUID)
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

  /// The first stored config that is the same config as `text`, the dedupe key.
  /// Compares a whitespace-normalized form, not raw bytes, so the same config does
  /// not duplicate over a trailing-newline or line-ending difference picked up from
  /// a file or NEVPN round trip. Internal, so the public helpers below use it
  /// without the extension reading as one uniform-access block.
  func firstMatchingText(_ text: String) -> StoredTunnelConfig? {
    let target = canonicalTunnelConfigText(text)
    return list().first { canonicalTunnelConfigText($0.text) == target }
  }

  /// The text of the stored config with this id, or `nil` when none matches.
  public func text(forID id: UUID) -> String? {
    list().first { $0.id == id }?.text
  }

  /// Reuses the existing entry when one already holds this same config, otherwise
  /// adds a new one, so importing or starting the same config never makes a
  /// duplicate. This is the one boundary where external text resolves to a library
  /// id; boot never adds rows.
  @discardableResult
  public func addDeduplicated(name: String, text: String) throws -> StoredTunnelConfig {
    if let existing = firstMatchingText(text) {
      return existing
    }
    return try add(name: name, text: text)
  }
}

// MARK: - Config text canonicalization

/// Normalizes config text for dedupe comparison only, never for storage: maps CRLF
/// to LF, trims each line, and drops blank lines, so two strings that describe the
/// same WireGuard config compare equal even when a file or NEVPN round trip added
/// or stripped whitespace. The stored text keeps its original bytes because that is
/// what starts the tunnel.
func canonicalTunnelConfigText(_ text: String) -> String {
  text
    .replacingOccurrences(of: "\r\n", with: "\n")
    .split(separator: "\n", omittingEmptySubsequences: false)
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty }
    .joined(separator: "\n")
}

// MARK: - InMemoryTunnelConfigStore

/// A non-persistent store for tests and previews. It keeps the library in memory
/// and applies the same ordering and active-clear rules as the keychain store.
public final class InMemoryTunnelConfigStore: TunnelConfigStore {
  private var configs: [StoredTunnelConfig] = []
  private var active: UUID?
  private let now: () -> Date
  private let makeID: () -> UUID

  public init(
    now: @escaping () -> Date = Date.init, makeID: @escaping () -> UUID = { UUID() }
  ) {
    self.now = now
    self.makeID = makeID
  }

  public func list() -> [StoredTunnelConfig] {
    configs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  public var activeID: UUID? { active }

  @discardableResult
  public func add(name: String, text: String) -> StoredTunnelConfig {
    let config = StoredTunnelConfig(id: makeID(), name: name, text: text, createdAt: now())
    configs.append(config)
    return config
  }

  public func update(id: UUID, text: String) throws {
    guard let index = configs.firstIndex(where: { $0.id == id }) else {
      throw TunnelConfigStoreError.notFound
    }
    configs[index].text = text
  }

  public func rename(id: UUID, name: String) throws {
    guard let index = configs.firstIndex(where: { $0.id == id }) else {
      throw TunnelConfigStoreError.notFound
    }
    configs[index].name = name
  }

  public func delete(id: UUID) {
    configs.removeAll { $0.id == id }
    if active == id {
      active = nil
    }
  }

  public func setActive(id: UUID) {
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

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

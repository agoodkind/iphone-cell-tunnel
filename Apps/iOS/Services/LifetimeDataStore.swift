//
//  LifetimeDataStore.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-03.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation

// MARK: - LifetimeDataTotals

/// One reading of the lifetime byte totals: transferred (sent), received, and their
/// sum, each accumulated across sessions.
struct LifetimeDataTotals: Equatable {
  var transferred: UInt64
  var received: UInt64

  var total: UInt64 {
    transferred &+ received
  }
}

// MARK: - LifetimeDataStore

/// Accumulates the relay sent and received byte totals across sessions so the screen
/// shows lifetime figures rather than the current session alone. The relay counters
/// reset to zero when a session restarts, so this folds each finished session's last
/// reading into a base persisted per direction in the app group, and reports the base
/// plus the live session reading. A session reset shows as the live reading dropping
/// below the last one.
struct LifetimeDataStore {
  /// The bases this store reads and writes, each already named for the direction
  /// the screen shows.
  private static let transferredKey = "lifetimeRelayBytesUploadBase"
  private static let receivedKey = "lifetimeRelayBytesDownloadBase"

  /// The bases written before the relay's byte directions were resolved per
  /// producer. They are read once to seed the current bases and are never
  /// written again.
  private static let priorTransferredKey = "lifetimeRelayBytesTransferredBase"
  private static let priorReceivedKey = "lifetimeRelayBytesReceivedBase"

  private let defaults: UserDefaults
  private var lastSessionTransferred: UInt64 = 0
  private var lastSessionReceived: UInt64 = 0

  init(suiteName: String = cellTunnelAppGroupIdentifier) {
    defaults = UserDefaults(suiteName: suiteName) ?? .standard
    seedBasesIfNeeded()
  }

  /// Seeds both current bases from the earlier pair whenever either is missing.
  /// The earlier pair is only read, so an interrupted seed leaves it intact and
  /// the next launch simply seeds again from the same values. Seeding on either
  /// key being absent, rather than on a separate completion marker, is what makes
  /// a half-written pair repair itself.
  private func seedBasesIfNeeded() {
    let hasBothBases =
      defaults.string(forKey: Self.transferredKey) != nil
      && defaults.string(forKey: Self.receivedKey) != nil
    guard !hasBothBases else {
      return
    }
    let priorTransferred = storedBase(Self.priorTransferredKey)
    let priorReceived = storedBase(Self.priorReceivedKey)
    #if targetEnvironment(macCatalyst)
      // The Mac folded its arriving bytes into the transferred base and its
      // leaving bytes into the received base, the reverse of what the screen
      // shows, so the two swap on the way across.
      persistBase(Self.transferredKey, priorReceived)
      persistBase(Self.receivedKey, priorTransferred)
    #else
      // The iPhone forwards for the Mac, so its bases already described the
      // directions the screen shows and they carry across unchanged.
      persistBase(Self.transferredKey, priorTransferred)
      persistBase(Self.receivedKey, priorReceived)
    #endif
  }

  /// Returns the lifetime transferred and received totals for a new per-session
  /// reading, folding a detected per-direction session reset into the persisted
  /// base first.
  mutating func totals(
    sessionTransferred: UInt64, sessionReceived: UInt64
  ) -> LifetimeDataTotals {
    if sessionTransferred < lastSessionTransferred {
      let folded = storedBase(Self.transferredKey) &+ lastSessionTransferred
      persistBase(Self.transferredKey, folded)
    }
    if sessionReceived < lastSessionReceived {
      let folded = storedBase(Self.receivedKey) &+ lastSessionReceived
      persistBase(Self.receivedKey, folded)
    }
    lastSessionTransferred = sessionTransferred
    lastSessionReceived = sessionReceived
    return LifetimeDataTotals(
      transferred: storedBase(Self.transferredKey) &+ sessionTransferred,
      received: storedBase(Self.receivedKey) &+ sessionReceived
    )
  }

  private func storedBase(_ key: String) -> UInt64 {
    guard let raw = defaults.string(forKey: key), let value = UInt64(raw) else {
      return 0
    }
    return value
  }

  private func persistBase(_ key: String, _ value: UInt64) {
    defaults.set(String(value), forKey: key)
  }
}

//
//  LifetimeDataStore.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-03.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation

// MARK: - LifetimeDataStore

/// Accumulates the relay byte total across sessions so the screen shows a lifetime
/// figure rather than the current session alone. The relay counters reset to zero
/// when a session restarts, so this folds each finished session's last total into a
/// base persisted in the app group, and reports the base plus the live session
/// total. A session reset shows as the live total dropping below the last reading.
struct LifetimeDataStore {
    private static let baseKey = "lifetimeRelayBytesBase"

    private let defaults: UserDefaults
    private var lastSessionTotal: UInt64 = 0

    init(suiteName: String = cellTunnelAppGroupIdentifier) {
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// Returns the lifetime total for a new per-session reading, folding a detected
    /// session reset into the persisted base first.
    mutating func total(sessionTotal: UInt64) -> UInt64 {
        if sessionTotal < lastSessionTotal {
            persistBase(storedBase() &+ lastSessionTotal)
        }
        lastSessionTotal = sessionTotal
        return storedBase() &+ sessionTotal
    }

    private func storedBase() -> UInt64 {
        guard let raw = defaults.string(forKey: Self.baseKey), let value = UInt64(raw) else {
            return 0
        }
        return value
    }

    private func persistBase(_ value: UInt64) {
        defaults.set(String(value), forKey: Self.baseKey)
    }
}

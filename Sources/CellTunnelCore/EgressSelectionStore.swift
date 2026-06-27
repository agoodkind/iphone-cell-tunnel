//
//  EgressSelectionStore.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-13.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation

private let logger = CellTunnelLog.logger(category: .daemon)
private let selectedEgressDeviceIDKey = "io.goodkind.celltunnel.selectedEgressDeviceID"

// MARK: - EgressSelectionStore

/// Persists which dialed-in iPhone the user chose for egress, keyed by the iPhone's
/// stable per-install device id, in the app-group `UserDefaults` the agent shares with
/// the extension. The device id survives the control-connection drops the iPhone takes
/// on every sleep/wake cycle, so the Mac re-binds egress to the same device when it
/// reconnects rather than losing the choice. This is the "which peer" selection only,
/// separate from the relay-enabled state, which the agent holds only in memory.
public enum EgressSelectionStore {
  private static var appGroupDefaults: UserDefaults {
    UserDefaults(suiteName: cellTunnelAppGroupIdentifier) ?? .standard
  }

  /// The remembered egress device id, or `nil` when none is chosen.
  public static func selectedDeviceID(from defaults: UserDefaults? = nil) -> String? {
    (defaults ?? appGroupDefaults).string(forKey: selectedEgressDeviceIDKey)
  }

  /// Stores the chosen egress device id, or clears it when `nil` or empty.
  public static func setSelectedDeviceID(
    _ deviceID: String?,
    to defaults: UserDefaults? = nil
  ) {
    let store = defaults ?? appGroupDefaults
    guard let deviceID, !deviceID.isEmpty else {
      store.removeObject(forKey: selectedEgressDeviceIDKey)
      logger.notice("egress selection cleared")
      return
    }
    store.set(deviceID, forKey: selectedEgressDeviceIDKey)
    logger.notice("egress selection saved")
  }

  /// Clears the remembered egress device id.
  public static func clear(in defaults: UserDefaults? = nil) {
    (defaults ?? appGroupDefaults).removeObject(forKey: selectedEgressDeviceIDKey)
    logger.notice("egress selection cleared")
  }
}

//
//  RelaySelectionStore.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-28.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation

private let selectedRelayServiceNameKey = "io.goodkind.celltunnel.selectedRelayServiceName"

/// Persists which discovered relay the user picked, keyed by its Bonjour service
/// name, in the app-group `UserDefaults` the agent shares with the extension.
/// The service name survives across browse cycles where the interface-scoped
/// identifier can change, so selection stays stable while the device reappears.
enum RelaySelectionStore {
  private static var defaults: UserDefaults? {
    UserDefaults(suiteName: cellTunnelAppGroupIdentifier)
  }

  static func selectedRelayServiceName() -> String? {
    defaults?.string(forKey: selectedRelayServiceNameKey)
  }

  static func setSelectedRelayServiceName(_ serviceName: String?) {
    guard let defaults else {
      return
    }
    if let serviceName {
      defaults.set(serviceName, forKey: selectedRelayServiceNameKey)
    } else {
      defaults.removeObject(forKey: selectedRelayServiceNameKey)
    }
  }
}

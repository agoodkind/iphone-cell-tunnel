//
//  RoutingIntentStore.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-09.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .daemon)
/// The defaults key holding the user's routing choice. Absent means the user has
/// never chosen, which reads as routing on.
private let routingIntentKey = "io.goodkind.celltunnel.routingEnabled"

// MARK: - RoutingIntentStore

/// The single durable owner of the user's routing intent. The agent loads it at
/// init and writes through on every change, so the intent survives the agent's
/// 60-second idle exit, a launchd kickstart, and a reboot. Routing defaults to on:
/// an unset key reads true, and `clear()` returns the system to that factory
/// state. Everything else (the phone's switch, the installed routes) derives from
/// this value; nothing else stores intent. The defaults database is a parameter so
/// tests run against a scratch suite.
public enum RoutingIntentStore {
  // MARK: - Access

  /// The persisted intent, true when the user has never chosen.
  public static func load(from defaults: UserDefaults = .standard) -> Bool {
    guard let stored = defaults.object(forKey: routingIntentKey) as? Bool else {
      return true
    }
    return stored
  }

  /// Persists the user's choice.
  public static func save(_ enabled: Bool, to defaults: UserDefaults = .standard) {
    defaults.set(enabled, forKey: routingIntentKey)
    logger.notice("routing intent saved enabled=\(enabled, privacy: .public)")
  }

  /// Removes the stored choice, restoring the default-on factory state. Reset
  /// calls this so a reset machine routes again without a tap.
  public static func clear(in defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: routingIntentKey)
    logger.notice("routing intent cleared to default-on")
  }
}

//
//  RelayController+ConfigLibrary.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-22.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation

private let configLibraryLogger = CellTunnelLog.logger(category: .relay)

// MARK: - Config operations

extension RelayController {
  /// Deletes a stored configuration.
  func deleteConfig(id: UUID) {
    configLibraryLogger.notice("relay controller delete config requested")
    Task { await backend.deleteConfig(id: id) }
  }

  /// Renames a stored configuration without touching tunnel state.
  func renameConfig(id: UUID, name: String) {
    configLibraryLogger.notice("relay controller rename config requested")
    Task { await backend.renameConfig(id: id, name: name) }
  }

  /// Creates a stored configuration from raw text without leaving it active, for the
  /// new-config flow. The agent activates a config on import, so the previously active
  /// config is restored afterward to keep New from stealing the current selection.
  func createConfig(name: String, text: String) {
    configLibraryLogger.notice("relay controller create config requested")
    let previousActiveID = activeConfigID
    if previousActiveID != nil {
      pinnedActiveConfigID = previousActiveID
    }
    Task {
      await backend.importConfig(name: name, text: text)
      if let previousActiveID {
        await backend.activateConfig(id: previousActiveID)
      }
      pinnedActiveConfigID = nil
    }
  }
}

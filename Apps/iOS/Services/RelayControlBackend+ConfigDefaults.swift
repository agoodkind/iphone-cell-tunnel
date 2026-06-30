//
//  RelayControlBackend+ConfigDefaults.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-30.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - RelayControlBackend config-op defaults

/// No-op config-library defaults for the backends with no library: the iPhone, the
/// simulator, and the previews. `Task.yield()` keeps each a real suspension point for the
/// async contract. `AgentRelayBackend` declares concrete members for every one of these
/// protocol requirements, so its real implementations win over these defaults.
extension RelayControlBackend {
  func loadConfigText(id _: UUID) async -> String? {
    await Task.yield()
    return nil
  }

  func importConfig(url _: URL, name _: String) async {
    await Task.yield()
  }

  func activateConfig(id _: UUID) async {
    await Task.yield()
  }

  func saveConfigEdit(id _: UUID, text _: String) async {
    await Task.yield()
  }

  func deleteConfig(id _: UUID) async {
    await Task.yield()
  }

  func renameConfig(id _: UUID, name _: String) async {
    await Task.yield()
  }

  func importConfig(name _: String, text _: String) async {
    await Task.yield()
  }
}

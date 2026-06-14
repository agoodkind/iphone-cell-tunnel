//
//  AgentTunnelController+Configs.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-13.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
@preconcurrency import NetworkExtension

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .daemon)
private let providerConfigWireGuardKey = "wireguardConfig"
private let reconciledConfigFallbackName = "Imported config"

// MARK: - Config library handling

extension AgentTunnelController {
  /// Validates, stores, activates, and starts a config from its text, then returns
  /// the refreshed status carrying the updated library.
  func handleImportConfig(name: String, text: String) async -> AgentControlResponse {
    do {
      _ = try WireGuardConfigParser.parse(text)
    } catch {
      logger.notice("agent import rejected config as unparseable recovery=return-invalid")
      return failure(errorCode: .unspecified, message: error.localizedDescription)
    }
    let saved: StoredTunnelConfig
    do {
      saved = try configStore.addDeduplicated(name: name, text: text)
      configStore.setActive(id: saved.id)
    } catch {
      logger.error("agent import config store failed recovery=return-failure")
      return failure(errorCode: .internal, message: "store config failed")
    }
    return await startStoredConfig(text: saved.text)
  }

  /// Makes a stored config active and starts the tunnel with it.
  func handleActivateConfig(id: String) async -> AgentControlResponse {
    guard let text = configStore.text(forID: id) else {
      return failure(errorCode: .internal, message: "no config with id \(id)")
    }
    configStore.setActive(id: id)
    return await startStoredConfig(text: text)
  }

  /// Saves edited config text and reloads the tunnel when that config is active.
  func handleSaveConfigEdit(id: String, text: String) async -> AgentControlResponse {
    do {
      _ = try WireGuardConfigParser.parse(text)
    } catch {
      logger.notice("agent save edit rejected config as unparseable recovery=return-invalid")
      return failure(errorCode: .unspecified, message: error.localizedDescription)
    }
    do {
      try configStore.update(id: id, text: text)
    } catch {
      logger.error("agent save config edit store failed recovery=return-failure")
      return failure(errorCode: .internal, message: "update config failed")
    }
    guard configStore.activeID == id else {
      return await handleStatus()
    }
    do {
      let path = try writeTempConfig(text)
      defer { removeTempConfig(at: path) }
      return await handleReloadTunnel(
        settings: TunnelStartSettings(wireGuardConfigPath: path))
    } catch {
      logger.error("agent save edit reload failed recovery=return-failure")
      return failure(from: error)
    }
  }

  /// Renames a stored config without touching tunnel state.
  func handleRenameConfig(id: String, name: String) async -> AgentControlResponse {
    do {
      try configStore.rename(id: id, name: name)
    } catch {
      logger.error("agent rename config failed recovery=return-failure")
      return failure(errorCode: .internal, message: "rename config failed")
    }
    return await handleStatus()
  }

  /// Deletes a stored config, stopping the tunnel first when it is the active one so
  /// nothing keeps running outside the library.
  func handleDeleteConfig(id: String) async -> AgentControlResponse {
    if configStore.activeID == id {
      _ = await handleStopTunnel()
    }
    do {
      try configStore.delete(id: id)
    } catch {
      logger.error("agent delete config failed recovery=return-failure")
      return failure(errorCode: .internal, message: "delete config failed")
    }
    return await handleStatus()
  }

  /// Returns the secret text of a stored config, fetched only for editing and never
  /// logged.
  func handleGetConfigText(id: String) -> AgentControlResponse {
    guard let text = configStore.text(forID: id) else {
      return failure(errorCode: .internal, message: "no config with id \(id)")
    }
    return AgentControlResponse(configText: text)
  }

  // MARK: - Auto-register and reconcile

  /// Records the config the tunnel is starting from into the library, deduped by
  /// content, and marks it active, so a config started over the command line still
  /// appears in the card.
  func registerActiveConfig(text: String, defaultName: String) {
    do {
      let saved = try configStore.addDeduplicated(name: defaultName, text: text)
      configStore.setActive(id: saved.id)
    } catch {
      logger.error("agent config auto-register failed recovery=continue-without-entry")
    }
  }

  /// Registers the currently-running config into an empty library on launch, named
  /// from the parsed endpoint host, so a relay started before this build still shows
  /// in the card on the first poll.
  func reconcileRunningConfig() async {
    do {
      let manager = try await loadOrCreateManager()
      guard
        let providerProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol,
        let providerConfiguration = providerProtocol.providerConfiguration,
        let text = providerConfiguration[providerConfigWireGuardKey] as? String,
        !text.isEmpty
      else {
        return
      }
      let host = Self.serverEndpoint(fromConfig: text)?.host ?? reconciledConfigFallbackName
      _ = try configStore.reconcileRunning(text: text, nameIfNew: host)
      logger.notice("agent reconciled running config into library")
    } catch {
      logger.error("agent reconcile running config failed recovery=skip")
    }
  }

  /// Removes every stored config, the factory-state clear the reset path uses.
  func clearConfigLibrary() {
    for config in configStore.list() {
      do {
        try configStore.delete(id: config.id)
      } catch {
        logger.error("agent config library clear failed recovery=continue")
      }
    }
  }

  // MARK: - Helpers

  /// The default library name for a config started by path, the file basename
  /// without its extension.
  static func configName(fromPath path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    let base = URL(fileURLWithPath: expanded).deletingPathExtension().lastPathComponent
    return base.isEmpty ? reconciledConfigFallbackName : base
  }

  /// Starts the tunnel from stored text by writing it to a short-lived temp file
  /// the start path reads, then removing the file once the start returns.
  private func startStoredConfig(text: String) async -> AgentControlResponse {
    do {
      let path = try writeTempConfig(text)
      defer { removeTempConfig(at: path) }
      return await handleStartTunnel(
        settings: TunnelStartSettings(wireGuardConfigPath: path))
    } catch {
      logger.error("agent start stored config failed recovery=return-failure")
      return failure(from: error)
    }
  }

  /// Writes config text to a unique temp file and returns its path. The text also
  /// lives in the saved VPN profile, so the temp file is no new exposure and is
  /// removed once the start path has read it.
  private func writeTempConfig(_ text: String) throws -> String {
    let directory = FileManager.default.temporaryDirectory
    let url = directory.appendingPathComponent("celltunnel-active-\(UUID().uuidString).conf")
    try Data(text.utf8).write(to: url, options: .atomic)
    logger.notice("agent wrote temp config for start recovery=remove-after-read")
    return url.path
  }

  /// Best-effort removal of a temp config file.
  private func removeTempConfig(at path: String) {
    do {
      try FileManager.default.removeItem(atPath: path)
    } catch {
      logger.error("agent temp config remove failed recovery=leave-temp-file")
    }
  }
}

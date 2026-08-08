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
private let importedConfigFallbackName = "Imported config"

// MARK: - Config library handling

extension AgentTunnelController {
  /// Validates and stores a config from its text, activating it when asked, then returns
  /// the refreshed status carrying the updated library.
  ///
  /// Adding a config and choosing which config is in force are separate things a person
  /// does, and one request settles both. Activating unconditionally meant a client that
  /// only wanted to add one had to send a second request to undo the activation, and
  /// anything that interrupted it between the two left the wrong config in force.
  ///
  /// Import resolves external text to a library entry and leaves relay start to the
  /// explicit start action.
  func handleImportConfig(
    name: String, text: String, activate: Bool
  ) async -> AgentControlResponse {
    do {
      _ = try WireGuardConfigParser.parse(text)
    } catch {
      logger.notice("agent import rejected config as unparseable recovery=return-invalid")
      return failure(errorCode: .unspecified, message: error.localizedDescription)
    }
    let saved: StoredTunnelConfig
    let previousActiveID = configStore.activeID
    do {
      saved = try configStore.addDeduplicated(name: name, text: text)
      if activate {
        configStore.setActive(id: saved.id)
      }
    } catch {
      logger.error(
        """
        agent import config store failed \
        details=\(String(describing: error), privacy: .public) recovery=return-failure
        """
      )
      // The app shows this message to a person, so it carries the recovery and no
      // internal prefix. The log line above keeps the underlying error verbatim.
      return failure(errorCode: .internal, message: userFacingMessage(for: error))
    }
    // Import leaves starting to the explicit start action, but a tunnel that is already
    // running must still carry what the library now calls active.
    if let followFailure = await followActiveConfigOnRunningTunnel() {
      restoreActiveConfig(to: previousActiveID)
      return followFailure
    }
    return await handleStatus()
  }

  /// Marks a stored config active without starting the tunnel.
  func handleSetActiveConfig(id: UUID) async -> AgentControlResponse {
    await activate(id: id)
  }

  /// Makes a stored config active without starting the tunnel. The relay session starts
  /// only through the routing-enable path, so this records the selection rather than
  /// starting anything.
  func handleActivateConfig(id: UUID) async -> AgentControlResponse {
    await activate(id: id)
  }

  /// Records which stored config is active and asks a running tunnel to carry it.
  ///
  /// Both activation requests do the same thing, so they share this rather than keeping
  /// two copies that can drift apart.
  ///
  /// A tunnel that cannot be made to carry the new selection puts the previous selection
  /// back before the failure is returned, so the library keeps naming the configuration
  /// the tunnel is actually running rather than the one that was asked for.
  private func activate(id: UUID) async -> AgentControlResponse {
    guard configStore.text(forID: id) != nil else {
      return failure(errorCode: .internal, message: "no config with id \(id.uuidString)")
    }
    let previousActiveID = configStore.activeID
    configStore.setActive(id: id)
    if let followFailure = await followActiveConfigOnRunningTunnel() {
      restoreActiveConfig(to: previousActiveID)
      return followFailure
    }
    return await handleStatus()
  }

  /// Saves edited config text and puts a running tunnel onto it when that config is the
  /// one in force. The id does not change, so the profile's stamp stays valid.
  func handleSaveConfigEdit(id: UUID, text: String) async -> AgentControlResponse {
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
    if let reapplyFailure = await reapplyEditedConfigToRunningTunnel(text: text, configID: id) {
      return reapplyFailure
    }
    return await handleStatus()
  }

  /// Renames a stored config without touching tunnel state.
  func handleRenameConfig(id: UUID, name: String) async -> AgentControlResponse {
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
  func handleDeleteConfig(id: UUID) async -> AgentControlResponse {
    if configStore.activeID == id {
      // Route through the disable path so routing state, the generation, the routes, and
      // the relay session all clear together, the same as turning the switch off.
      await disableRouting()
      // The tunnel is stopped and the config is gone, so any prior drift is moot.
      configDriftMessage = nil
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
  func handleGetConfigText(id: UUID) -> AgentControlResponse {
    guard let text = configStore.text(forID: id) else {
      return failure(errorCode: .internal, message: "no config with id \(id.uuidString)")
    }
    return AgentControlResponse(configText: text)
  }

  // MARK: - Boot assertion

  /// Asserts on launch that the running tunnel's stamped config id agrees with the
  /// library's active selection. This never creates or changes a library row, so it
  /// cannot split-brain the way a row-creating reconcile could: a genuine mismatch is
  /// surfaced loudly, an unstamped tunnel trusts the library, and the verdict is
  /// published on every status snapshot's `configDrift`.
  func assertRunningConfigMatchesLibrary() async {
    do {
      let manager = try await loadOrCreateManager()
      guard isSessionActive(on: manager) else {
        configDriftMessage = nil
        return
      }
      guard
        let providerProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol,
        let providerConfiguration = providerProtocol.providerConfiguration
      else {
        configDriftMessage = nil
        return
      }
      let runningRaw = providerConfiguration[Self.providerConfigConfigIDKey] as? String
      let runningID = runningRaw.flatMap(UUID.init(uuidString:))
      if let runningRaw, !runningRaw.isEmpty, runningID == nil {
        let message = "running tunnel carries an unparseable config id"
        configDriftMessage = message
        logger.error(
          "agent config assertion mismatch \(message, privacy: .public) recovery=surface-no-mutation"
        )
        return
      }
      let libraryIDs = Set(configStore.list().map(\.id))
      switch evaluateConfigLibraryDrift(
        runningConfigID: runningID, activeID: configStore.activeID, libraryIDs: libraryIDs)
      {
      case .ok:
        configDriftMessage = nil
      case .unstamped:
        configDriftMessage = "running tunnel has no config id; trusting library active selection"
        logger.notice("agent config assertion unstamped recovery=trust-library")
      case .mismatch:
        let message =
          "running config id \(runningID?.uuidString ?? "nil") "
          + "is not the library active id \(configStore.activeID?.uuidString ?? "nil")"
        configDriftMessage = message
        logger.error(
          "agent config assertion mismatch \(message, privacy: .public) recovery=surface-no-mutation"
        )
      }
    } catch {
      logger.error(
        """
        agent config assertion failed \
        details=\(String(describing: error), privacy: .public) recovery=skip
        """
      )
    }
  }

  // MARK: - Helpers

  /// The default library name for a config started by path, the file basename
  /// without its extension.
  static func configName(fromPath path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    let base = URL(fileURLWithPath: expanded).deletingPathExtension().lastPathComponent
    return base.isEmpty ? importedConfigFallbackName : base
  }

}

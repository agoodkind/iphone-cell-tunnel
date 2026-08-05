//
//  RelayController+ConfigLibrary.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-22.
//  Copyright © 2026, all rights reserved.
//

#if targetEnvironment(macCatalyst)
  import CellTunnelLog
  import Foundation

  private let configLibraryLogger = CellTunnelLog.logger(category: .relay)

  // MARK: - Config library actions

  extension RelayController {
    /// Registers the background agent, the install-agent setup action.
    func installAgent() {
      configLibraryLogger.notice("relay controller install agent requested")
      Task { await installState.registerAgent() }
    }

    /// Opens Network settings so the user can switch a disabled VPN profile back on.
    func openVPNSettings() {
      configLibraryLogger.notice("relay controller open vpn settings requested")
      installState.openVPNSettings()
    }

    /// Opens the settings pane where local network access is granted, which is what a
    /// Mac needs before an iPhone can find it.
    func openLocalNetworkSettings() {
      configLibraryLogger.notice("relay controller open local network settings requested")
      installState.openLocalNetworkSettings()
    }

    /// Opens Login Items so the user can approve a registered-but-pending agent.
    func openLoginItems() {
      configLibraryLogger.notice("relay controller open login items requested")
      installState.openLoginItems()
    }

    /// Imports the initial tunnel configuration into the agent library.
    func installTunnel(configURL: URL) async {
      configLibraryLogger.notice("relay controller install tunnel requested")
      await configLibraryBackend.installTunnel(configURL: configURL)
    }

    /// Loads a stored configuration's secret text on demand for the editor.
    func loadConfigText(id: UUID) async -> String? {
      configLibraryLogger.notice("relay controller load config text requested")
      return await configLibraryBackend.loadConfigText(id: id)
    }

    /// Imports a picked configuration file, then validates, stores, and applies it.
    func importConfig(url: URL, name: String) async throws {
      configLibraryLogger.notice("relay controller import config requested")
      try await configLibraryBackend.importConfig(url: url, name: name)
    }

    /// Makes a stored configuration active and applies it.
    func activateConfig(id: UUID) {
      configLibraryLogger.notice("relay controller activate config requested")
      activeConfigID = id
      Task { await configLibraryBackend.activateConfig(id: id) }
    }

    /// Saves edited configuration text and reloads it when it is active.
    func saveConfigEdit(id: UUID, text: String) {
      configLibraryLogger.notice("relay controller save config edit requested")
      Task { await configLibraryBackend.saveConfigEdit(id: id, text: text) }
    }

    /// Deletes a stored configuration.
    func deleteConfig(id: UUID) {
      configLibraryLogger.notice("relay controller delete config requested")
      Task { await configLibraryBackend.deleteConfig(id: id) }
    }

    /// Renames a stored configuration without touching tunnel state.
    func renameConfig(id: UUID, name: String) {
      configLibraryLogger.notice("relay controller rename config requested")
      Task { await configLibraryBackend.renameConfig(id: id, name: name) }
    }

    /// Adds a stored configuration from raw text without changing which one is in force,
    /// for the new-configuration flow.
    ///
    /// This asks for exactly that in one request. It used to add the configuration, let
    /// it become active, and send a second request undoing that, which left the wrong
    /// configuration in force if anything interrupted the two.
    func createConfig(name: String, text: String) {
      configLibraryLogger.notice("relay controller create config requested")
      Task {
        do {
          try await configLibraryBackend.importConfig(
            name: name, text: text, activate: false)
        } catch {
          configLibraryLogger.error(
            """
            relay controller create config failed \
            details=\(String(describing: error), privacy: .public) recovery=keep-state
            """
          )
        }
      }
    }
  }
#endif

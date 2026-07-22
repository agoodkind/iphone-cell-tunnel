//
//  ConfigLibraryBackend.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-21.
//  Copyright © 2026, all rights reserved.
//

#if targetEnvironment(macCatalyst)
  import Foundation

  // MARK: - ConfigLibraryBackend

  /// The Mac-only capability for importing and managing the agent-owned WireGuard
  /// configuration library. It is unavailable to the iPhone target, which can only
  /// approve its own VPN configuration and control shared relay routing.
  @MainActor
  protocol ConfigLibraryBackend {
    /// Imports a selected configuration as the initial tunnel configuration.
    func installTunnel(configURL: URL) async

    /// Fetches one stored configuration's text for the editor.
    func loadConfigText(id: UUID) async -> String?

    /// Imports a selected configuration file into the agent library.
    func importConfig(url: URL, name: String) async

    /// Creates a configuration from raw editor text.
    func importConfig(name: String, text: String) async

    /// Marks one stored configuration active.
    func activateConfig(id: UUID) async

    /// Saves an edited stored configuration.
    func saveConfigEdit(id: UUID, text: String) async

    /// Deletes one stored configuration.
    func deleteConfig(id: UUID) async

    /// Renames one stored configuration.
    func renameConfig(id: UUID, name: String) async
  }
#endif

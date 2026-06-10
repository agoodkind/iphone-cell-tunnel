//
//  AgentRelayBackend.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-31.
//  Copyright © 2026, all rights reserved.
//

#if targetEnvironment(macCatalyst)
  import CellTunnelCore
  import CellTunnelLog
  import Foundation

  private let logger = CellTunnelLog.logger(category: .relay)

  // The file name the imported tunnel config is copied to inside the shared
  // app-group container, where the agent reads it to start the tunnel.
  private let importedTunnelConfigName = "imported-tunnel.conf"

  // MARK: - AgentRelayBackend

  /// Drives the Mac relay UI by reading the headless agent over XPC. The agent
  /// owns the Mac tunnel, so this backend only reads status; it does not bring a
  /// tunnel up or down. It maps the agent's status snapshot onto the shared
  /// reading the views render.
  ///
  /// The Mac and the command-line tool share one control client, `AgentClient`,
  /// which connects to the agent's mach service with the libxpc session API.
  @MainActor
  final class AgentRelayBackend: RelayControlBackend {
    private let client = AgentClient()
    private let store = KeychainTunnelConfigStore()

    // MARK: - Lifecycle

    // The agent owns the Mac tunnel, so the Mac UI does not start or stop it. It
    // does ask the agent to begin relay discovery so the peers list populates.
    func start() async {
      logger.notice("agent relay backend start: read-only, requesting relay discovery")
      do {
        _ = try await client.startRelayDiscovery()
        logger.notice("agent relay backend relay discovery started")
      } catch {
        logger.error(
          """
          agent relay backend discovery start failed \
          details=\(String(describing: error), privacy: .public) recovery=retry-on-sample
          """
        )
      }
    }

    /// The Mac setup gating comes from the agent's status snapshot, so launch proceeds.
    func tunnelProvisioned() async -> Bool {
      await Task.yield()
      return true
    }

    // Sends the routing choice to the agent, which installs or withdraws the
    // program routes.
    func setRouting(enabled: Bool) async {
      do {
        _ = try await client.setRoutingEnabled(enabled)
        logger.notice(
          "agent relay backend routing sent enabled=\(enabled, privacy: .public)")
      } catch {
        logger.error(
          """
          agent relay backend routing change failed \
          details=\(String(describing: error), privacy: .public) recovery=keep-state
          """
        )
      }
    }

    // MARK: - Peer selection

    // Forwards the peer selection to the agent, which records it and uses it the
    // next time it builds the tunnel.
    func selectPeer(id: String) async {
      do {
        _ = try await client.selectRelayService(serviceID: id)
        logger.notice("agent relay backend peer selection sent id=\(id, privacy: .public)")
      } catch {
        logger.error(
          """
          agent relay backend peer selection failed \
          details=\(String(describing: error), privacy: .public) recovery=keep-state
          """
        )
      }
    }

    // MARK: - Tunnel install

    // Copies the imported config into the shared app-group container, where the
    // agent can read it, then asks the agent to start the tunnel from that path.
    func installTunnel(configURL: URL) async {
      do {
        let path = try copyConfigIntoSharedContainer(configURL)
        _ = try await client.startTunnel(
          settings: TunnelStartSettings(wireGuardConfigPath: path))
        logger.notice("agent relay backend tunnel install requested")
      } catch {
        logger.error(
          """
          agent relay backend tunnel install failed \
          details=\(String(describing: error), privacy: .public) recovery=keep-state
          """
        )
      }
    }

    // MARK: - Config library

    /// Lists the stored WireGuard configurations in the Catalyst keychain store.
    func listConfigs() -> [StoredTunnelConfig] {
      store.list()
    }

    /// The stored configuration currently selected as active.
    var activeConfigID: String? {
      store.activeID
    }

    /// Imports, validates, stores, selects, and applies one WireGuard config file.
    func importConfig(url: URL, name: String) async {
      let text: String
      let accessing = url.startAccessingSecurityScopedResource()
      defer {
        if accessing {
          url.stopAccessingSecurityScopedResource()
        }
      }
      do {
        text = try String(contentsOf: url, encoding: .utf8)
      } catch {
        logger.error(
          """
          agent relay backend config import read failed \
          details=\(String(describing: error), privacy: .public) recovery=keep-state
          """
        )
        return
      }

      do {
        try await client.validateConfig(text: text)
      } catch {
        logger.error(
          """
          agent relay backend import rejected invalid config recovery=keep-state
          """
        )
        return
      }

      do {
        let saved = try store.add(name: name, text: text)
        store.setActive(id: saved.id)
        let path = try writeConfigTextToContainer(text)
        _ = try await client.startTunnel(
          settings: TunnelStartSettings(wireGuardConfigPath: path))
        logger.notice(
          "agent relay backend config imported id=\(saved.id, privacy: .public)"
        )
      } catch {
        logger.error(
          """
          agent relay backend config import apply failed \
          details=\(String(describing: error), privacy: .public) \
          recovery=stored-not-started
          """
        )
      }
    }

    /// Selects and applies a stored WireGuard configuration by id.
    func activateConfig(id: String) async {
      guard let config = store.list().first(where: { $0.id == id }) else {
        logger.error(
          """
          agent relay backend config activation missing \
          id=\(id, privacy: .public) recovery=keep-state
          """
        )
        return
      }

      store.setActive(id: id)
      do {
        let path = try writeConfigTextToContainer(config.text)
        _ = try await client.startTunnel(
          settings: TunnelStartSettings(wireGuardConfigPath: path))
        logger.notice("agent relay backend config activated id=\(id, privacy: .public)")
      } catch {
        logger.error(
          """
          agent relay backend config activation failed \
          id=\(id, privacy: .public) \
          details=\(String(describing: error), privacy: .public) \
          recovery=selection-stored-not-started
          """
        )
      }
    }

    /// Saves edited WireGuard config text and reloads the tunnel when it is active.
    func saveConfigEdit(id: String, text: String) async {
      do {
        try await client.validateConfig(text: text)
      } catch {
        logger.error(
          """
          agent relay backend save rejected invalid config \
          id=\(id, privacy: .public) recovery=keep-state
          """
        )
        return
      }

      do {
        try store.update(id: id, text: text)
        logger.notice("agent relay backend config edit saved id=\(id, privacy: .public)")
      } catch {
        logger.error(
          """
          agent relay backend config edit store failed \
          id=\(id, privacy: .public) \
          details=\(String(describing: error), privacy: .public) recovery=keep-state
          """
        )
        return
      }

      guard store.activeID == id else {
        return
      }

      do {
        let path = try writeConfigTextToContainer(text)
        _ = try await client.reloadTunnel(
          settings: TunnelStartSettings(wireGuardConfigPath: path))
        logger.notice(
          "agent relay backend active config edit reloaded id=\(id, privacy: .public)"
        )
      } catch {
        logger.error(
          """
          agent relay backend reload after edit failed \
          id=\(id, privacy: .public) \
          details=\(String(describing: error), privacy: .public) \
          recovery=stored-not-reloaded
          """
        )
      }
    }

    /// Renames a stored WireGuard configuration.
    func renameConfig(id: String, name: String) async {
      await Task.yield()
      do {
        try store.rename(id: id, name: name)
        logger.notice("agent relay backend config renamed id=\(id, privacy: .public)")
      } catch {
        logger.error(
          """
          agent relay backend config rename failed \
          id=\(id, privacy: .public) \
          details=\(String(describing: error), privacy: .public) recovery=keep-state
          """
        )
      }
    }

    /// Deletes a stored WireGuard configuration.
    func deleteConfig(id: String) async {
      await Task.yield()
      do {
        try store.delete(id: id)
        logger.notice("agent relay backend config deleted id=\(id, privacy: .public)")
      } catch {
        logger.error(
          """
          agent relay backend config delete failed \
          id=\(id, privacy: .public) \
          details=\(String(describing: error), privacy: .public) recovery=keep-state
          """
        )
      }
    }

    /// Writes config text into the shared app-group container for the agent.
    private func writeConfigTextToContainer(_ text: String) throws -> String {
      guard
        let container = FileManager.default.containerURL(
          forSecurityApplicationGroupIdentifier: cellTunnelAppGroupIdentifier)
      else {
        throw AgentRelayBackendError.sharedContainerUnavailable
      }
      let destination = container.appendingPathComponent(importedTunnelConfigName)
      let data = Data(text.utf8)
      try data.write(to: destination, options: .atomic)
      logger.notice("agent relay backend wrote imported config into shared container")
      return destination.path
    }

    /// Reads a security-scoped config file and writes its text into the container.
    private func copyConfigIntoSharedContainer(_ source: URL) throws -> String {
      let accessing = source.startAccessingSecurityScopedResource()
      defer {
        if accessing {
          source.stopAccessingSecurityScopedResource()
        }
      }
      let text = try String(contentsOf: source, encoding: .utf8)
      return try writeConfigTextToContainer(text)
    }

    // MARK: - Sampling

    func sample() async -> RelayStatusSample? {
      do {
        var snapshot = try await client.status()
        snapshot.discovery = await discoverySnapshot()
        return RelayStatusSample(snapshot: snapshot)
      } catch {
        logger.error(
          """
          agent relay status read failed \
          details=\(String(describing: error), privacy: .public) recovery=keep-last-reading
          """
        )
        return nil
      }
    }

    // The status snapshot the agent forwards from the extension carries no
    // discovery, so the peers list is read from the agent's own browser. A
    // discovery read failure yields an empty section rather than failing the poll.
    private func discoverySnapshot() async -> TunnelDiscoverySnapshot {
      do {
        return try await client.listRelayServices()
      } catch {
        logger.error(
          """
          agent relay discovery read failed \
          details=\(String(describing: error), privacy: .public) recovery=empty-discovery
          """
        )
        return TunnelDiscoverySnapshot()
      }
    }
  }

  // MARK: - AgentRelayBackendError

  enum AgentRelayBackendError: LocalizedError {
    case sharedContainerUnavailable

    var errorDescription: String? {
      switch self {
      case .sharedContainerUnavailable:
        return "the shared app-group container is unavailable for the imported config"
      }
    }
  }

#endif

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

    private func copyConfigIntoSharedContainer(_ source: URL) throws -> String {
      let accessing = source.startAccessingSecurityScopedResource()
      defer {
        if accessing {
          source.stopAccessingSecurityScopedResource()
        }
      }
      guard
        let container = FileManager.default.containerURL(
          forSecurityApplicationGroupIdentifier: cellTunnelAppGroupIdentifier)
      else {
        throw AgentRelayBackendError.sharedContainerUnavailable
      }
      let destination = container.appendingPathComponent(importedTunnelConfigName)
      let data = try Data(contentsOf: source)
      try data.write(to: destination, options: .atomic)
      logger.notice("agent relay backend copied imported config into shared container")
      return destination.path
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

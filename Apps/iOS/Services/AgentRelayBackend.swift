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

  // MARK: - AgentRelayBackend

  /// Drives the Mac relay UI by reading the headless agent over XPC. The agent
  /// owns the Mac tunnel and the config library, so this backend reads status and
  /// forwards every config mutation over XPC; it holds no local store. It maps the
  /// agent's status snapshot onto the shared reading the views render.
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

    // The Mac's available peers are the dialed-in roster, so the status word reflects
    // connected iPhones rather than Bonjour discovery.
    var usesEgressRoster: Bool {
      true
    }

    // Forwards the egress-iPhone choice to the agent, which installs that iPhone's
    // relay session so the bridge routes egress through it.
    func selectEgressPeer(id: String) async {
      do {
        _ = try await client.selectEgressPeer(peerID: id)
        logger.notice(
          "agent relay backend egress selection sent id=\(id, privacy: .public)")
      } catch {
        logger.error(
          """
          agent relay backend egress selection failed \
          details=\(String(describing: error), privacy: .public) recovery=keep-state
          """
        )
      }
    }

    // MARK: - Tunnel install

    // Reads the imported config and asks the agent to import it, which validates,
    // stores, activates, and starts it. The agent owns the library, so the install
    // setup action and the Configs import share one path.
    func installTunnel(configURL: URL) async {
      await importConfig(url: configURL, name: defaultName(from: configURL))
    }

    // MARK: - Config library

    /// Reads a picked config file and asks the agent to import it: validate, store,
    /// activate, and start. The text crosses to the agent over XPC; the agent owns
    /// the keychain storage.
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
        _ = try await client.importConfig(name: name, text: text)
        logger.notice("agent relay backend config import forwarded")
      } catch {
        logger.error(
          """
          agent relay backend config import forward failed \
          details=\(String(describing: error), privacy: .public) recovery=keep-state
          """
        )
      }
    }

    /// Asks the agent to make a stored config active and start the tunnel with it.
    func activateConfig(id: String) async {
      do {
        _ = try await client.activateConfig(id: id)
        logger.notice("agent relay backend config activate forwarded id=\(id, privacy: .public)")
      } catch {
        logger.error(
          """
          agent relay backend config activate forward failed \
          id=\(id, privacy: .public) \
          details=\(String(describing: error), privacy: .public) recovery=keep-state
          """
        )
      }
    }

    /// Asks the agent to save edited config text and reload when that config is active.
    func saveConfigEdit(id: String, text: String) async {
      do {
        _ = try await client.saveConfigEdit(id: id, text: text)
        logger.notice("agent relay backend config edit forwarded id=\(id, privacy: .public)")
      } catch {
        logger.error(
          """
          agent relay backend config edit forward failed \
          id=\(id, privacy: .public) \
          details=\(String(describing: error), privacy: .public) recovery=keep-state
          """
        )
      }
    }

    /// Asks the agent to rename a stored config.
    func renameConfig(id: String, name: String) async {
      do {
        _ = try await client.renameConfig(id: id, name: name)
        logger.notice("agent relay backend config rename forwarded id=\(id, privacy: .public)")
      } catch {
        logger.error(
          """
          agent relay backend config rename forward failed \
          id=\(id, privacy: .public) \
          details=\(String(describing: error), privacy: .public) recovery=keep-state
          """
        )
      }
    }

    /// Asks the agent to delete a stored config, which stops the tunnel first when it
    /// is the active one.
    func deleteConfig(id: String) async {
      do {
        _ = try await client.deleteConfig(id: id)
        logger.notice("agent relay backend config delete forwarded id=\(id, privacy: .public)")
      } catch {
        logger.error(
          """
          agent relay backend config delete forward failed \
          id=\(id, privacy: .public) \
          details=\(String(describing: error), privacy: .public) recovery=keep-state
          """
        )
      }
    }

    /// Fetches a stored config's secret text from the agent for the editor only.
    func loadConfigText(id: String) async -> String? {
      do {
        return try await client.getConfigText(id: id)
      } catch {
        logger.error(
          """
          agent relay backend config text read failed \
          id=\(id, privacy: .public) \
          details=\(String(describing: error), privacy: .public) recovery=nil-text
          """
        )
        return nil
      }
    }

    /// The default library name for an imported file, its basename without the
    /// extension.
    private func defaultName(from url: URL) -> String {
      url.deletingPathExtension().lastPathComponent
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

#endif

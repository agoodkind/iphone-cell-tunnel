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
  final class AgentRelayBackend: RelayControlBackend, ConfigLibraryBackend {
    private let client = AgentClient()

    // MARK: - Lifecycle

    // The Mac starts the agent's control pairing path on launch so the iPhone can
    // appear in the peer roster before any relay session starts.
    func start() async {
      logger.notice("agent relay backend start: requesting control pairing")
      do {
        _ = try await client.startPairing()
        logger.notice("agent relay backend control pairing started")
      } catch {
        logger.error(
          """
          agent relay backend pairing start failed \
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
      do {
        try await importConfig(url: configURL, name: defaultName(from: configURL))
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

    /// Reads a picked config file and asks the agent to import it: validate, store,
    /// activate, and start. The text crosses to the agent over XPC; the agent owns
    /// the keychain storage.
    func importConfig(url: URL, name: String) async throws {
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
        throw error
      }

      // Importing a file is a person choosing a configuration to use, so it becomes the
      // active one. Adding one to the library without changing which is in force is the
      // new-configuration flow, which asks for that explicitly.
      _ = try await importConfig(name: name, text: text, activate: true)
    }

    /// Adds a config from raw text through the agent, which validates and stores it, and
    /// activates it when asked. The new-config flow and the file import share this path.
    ///
    /// Returns the active config id the agent reported after the import, so a caller
    /// that asked for no activation can see whether an older agent, which predates the
    /// choice and always activates, changed the selection anyway.
    func importConfig(name: String, text: String, activate: Bool) async throws -> UUID? {
      do {
        let snapshot = try await client.importConfig(name: name, text: text, activate: activate)
        logger.notice("agent relay backend config create forwarded")
        return snapshot.activeConfigID
      } catch {
        logger.error(
          """
          agent relay backend config create forward failed \
          details=\(String(describing: error), privacy: .public) recovery=keep-state
          """
        )
        throw error
      }
    }

    /// Forwards one id-keyed config mutation to the agent and logs the shared
    /// `config <verb> forwarded` and `config <verb> forward failed` outcome, keeping local
    /// state on failure so a dropped XPC call does not desync the library.
    private func forwardConfigMutation(
      _ verb: String,
      id: UUID,
      _ work: () async throws -> Void
    ) async {
      do {
        try await work()
        logger.notice(
          """
          agent relay backend config \(verb, privacy: .public) forwarded \
          id=\(id.uuidString, privacy: .public)
          """
        )
      } catch {
        logger.error(
          """
          agent relay backend config \(verb, privacy: .public) forward failed \
          id=\(id.uuidString, privacy: .public) \
          details=\(String(describing: error), privacy: .public) recovery=keep-state
          """
        )
      }
    }

    /// Asks the agent to rename a stored config, metadata only, leaving tunnel state.
    func renameConfig(id: UUID, name: String) async {
      await forwardConfigMutation("rename", id: id) {
        _ = try await client.renameConfig(id: id, name: name)
      }
    }

    /// Asks the agent to mark a stored config active without starting relay.
    func activateConfig(id: UUID) async {
      await forwardConfigMutation("activate", id: id) {
        _ = try await client.setActiveConfig(id: id)
      }
    }

    /// Asks the agent to save edited config text and reload when that config is active.
    func saveConfigEdit(id: UUID, text: String) async {
      await forwardConfigMutation("edit", id: id) {
        _ = try await client.saveConfigEdit(id: id, text: text)
      }
    }

    /// Asks the agent to delete a stored config, which stops the tunnel first when it
    /// is the active one.
    func deleteConfig(id: UUID) async {
      await forwardConfigMutation("delete", id: id) {
        _ = try await client.deleteConfig(id: id)
      }
    }

    /// Fetches a stored config's secret text from the agent for the editor only.
    func loadConfigText(id: UUID) async -> String? {
      do {
        return try await client.getConfigText(id: id)
      } catch {
        logger.error(
          """
          agent relay backend config text read failed \
          id=\(id.uuidString, privacy: .public) \
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

    // MARK: - Status

    /// Subscribes to the agent's pushes and yields one reading per snapshot.
    ///
    /// The stream is the subscription: it opens when the caller starts reading it and
    /// finishes when the agent goes away, which is how the caller learns the agent is
    /// unreachable without asking once a second. Ending the read shuts the client down,
    /// so putting the app in the background stops the pushes at the source rather than
    /// ignoring them here.
    func statusUpdates() -> AsyncStream<RelayStatusSample>? {
      let agentClient = self.client
      return AsyncStream { continuation in
        let subscribeTask = Task {
          do {
            let current = try await agentClient.subscribe(
              onSnapshot: { snapshot in
                continuation.yield(Self.sample(from: snapshot))
              },
              onDisconnect: {
                continuation.finish()
              }
            )
            continuation.yield(Self.sample(from: current))
            logger.notice("agent relay backend subscribed to status pushes")
          } catch {
            logger.error(
              """
              agent relay subscribe failed \
              details=\(String(describing: error), privacy: .public) recovery=end-stream
              """
            )
            continuation.finish()
          }
        }
        continuation.onTermination = { _ in
          subscribeTask.cancel()
          Task { await agentClient.shutdown() }
        }
      }
    }

    /// Maps one agent snapshot onto the shared reading.
    ///
    /// Static and off the main thread because the pushes arrive on the transport's own
    /// queue and nothing here touches the backend's state. The agent's snapshot reports
    /// the configuration library rather than a saved profile, so whether a tunnel is
    /// installed is read from the library.
    nonisolated private static func sample(
      from snapshot: TunnelDaemonStatusSnapshot
    ) -> RelayStatusSample {
      var sample = RelayStatusSample(snapshot: snapshot)
      sample.isTunnelInstalled =
        snapshot.activeConfigID != nil || !(snapshot.configLibrary ?? []).isEmpty
      return sample
    }
  }

#endif

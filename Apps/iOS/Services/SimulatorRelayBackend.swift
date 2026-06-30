//
//  SimulatorRelayBackend.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-02.
//  Copyright © 2026, all rights reserved.
//

#if !targetEnvironment(macCatalyst)
  import CellTunnelCore
  import CellTunnelLog
  import CellTunnelRelay
  import Foundation
  import UIKit

  private let logger = CellTunnelLog.logger(category: .relay)

  // MARK: - SimulatorRelayBackend

  /// Hosts the real relay runtime in-process for the iOS Simulator, where the
  /// Network Extension packet tunnel has no launchable `nehelper` to start it.
  /// `PhoneRelayBackend` delegates here in the simulator. The runtime is the same
  /// engine the on-device packet tunnel hosts, so the simulator exercises the real
  /// control link, discovery, forwarder, and status path; only the background
  /// tunnel host is absent, which a foreground app does not need. It is the
  /// simulator composition root: it builds the host-network graph, where each
  /// connection egresses over the host network instead of a pinned interface.
  @MainActor
  final class SimulatorRelayBackend: RelayControlBackend {
    private let runtime = RelayRuntime(
      composition: .hostNetwork(
        deviceName: UIDevice.current.name,
        deviceID: relayServiceDeviceID(
          defaults: UserDefaults(suiteName: cellTunnelAppGroupIdentifier) ?? .standard
        )
      )
    )

    // MARK: - Lifecycle

    func start() async {
      await Task.yield()
      logger.notice("simulator relay backend starting in-process relay runtime")
      runtime.start()
    }

    /// The simulator hosts the relay in process, so launch gating always proceeds.
    func tunnelProvisioned() async -> Bool {
      await Task.yield()
      return true
    }

    // MARK: - Sampling

    func sample() async -> RelayStatusSample? {
      await Task.yield()
      return RelayStatusSample(snapshot: runtime.statusSnapshot())
    }

    // MARK: - Routing

    // Sends the routing choice to the agent over the runtime's real control
    // link, which installs or withdraws the program routes.
    func setRouting(enabled: Bool) async {
      await Task.yield()
      logger.notice(
        "simulator relay backend routing enabled=\(enabled, privacy: .public)")
      runtime.setRoutingEnabled(enabled)
    }

    // MARK: - Peer selection

    // The simulator iPhone is a dumb dialer with no manual picker, so it auto-dials
    // the first discovered Mac when none is selected.
    var autoSelectsDiscoveredPeer: Bool {
      true
    }

    // Records the chosen Mac control service and dials it through the in-process
    // runtime's control link.
    func selectPeer(id: String) async {
      await Task.yield()
      logger.notice("simulator relay backend select peer id=\(id, privacy: .public)")
      runtime.selectPeer(id: id)
    }

    func selectEgressPeer(id _: String) async {
      await Task.yield()
    }

    // MARK: - Tunnel install

    // The in-process relay needs no saved profile and no WireGuard config, so the
    // install action just brings the runtime up.
    func installTunnel(configURL _: URL) async {
      await Task.yield()
      logger.notice("simulator relay backend install tunnel: starting runtime")
      runtime.start()
    }

    // MARK: - Config library

    // The in-process simulator relay hosts no config library.
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

#endif

//
//  UITestFixture.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-22.
//  Copyright © 2026, all rights reserved.
//

#if DEBUG
  import CellTunnelCore
  import Foundation

  // MARK: - UITestFixture

  enum UITestFixture {
    static let fixtureConfigCreationTimeInterval: TimeInterval = 1_721_000_000
    static let fixtureConfigIdentifier = UUID(
      uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)
    )
    static let fixtureConfigCreationDate =
      Date(timeIntervalSince1970: fixtureConfigCreationTimeInterval)

    #if targetEnvironment(macCatalyst)
      static let scrollRecoveryMarkerTitle = "Fixture scroll recovery marker"
      static let scrollRecoveryMarkerTopPadding: CGFloat = 1_000
    #endif

    private static let provisionedArgument = "--cell-tunnel-ui-test-fixture"
    private static let approvalRequiredArgument = "--cell-tunnel-ui-test-approval-required"
    private static let approvalRequiredEnvironment =
      "CELL_TUNNEL_UI_TEST_APPROVAL_REQUIRED"
    private static let defaultsSuiteName = "CellTunnelPhoneUITests"

    static var isEnabled: Bool {
      let arguments = ProcessInfo.processInfo.arguments
      return arguments.contains(provisionedArgument) || requiresApproval
    }

    @MainActor static func makeRelayController() -> RelayController {
      let backend = UITestFixtureBackend(isTunnelProvisioned: !requiresApproval)
      #if targetEnvironment(macCatalyst)
        return RelayController(
          backend: backend,
          throughput: ThroughputCalculator(),
          lifetimeStore: LifetimeDataStore(suiteName: defaultsSuiteName),
          installState: InstallationState(),
          deviceProbe: nil
        )
      #else
        return RelayController(
          backend: backend,
          throughput: ThroughputCalculator(),
          lifetimeStore: LifetimeDataStore(suiteName: defaultsSuiteName),
          deviceProbe: nil
        )
      #endif
    }

    private static var requiresApproval: Bool {
      let environment = ProcessInfo.processInfo.environment
      return ProcessInfo.processInfo.arguments.contains(approvalRequiredArgument)
        || environment[approvalRequiredEnvironment] == "1"
    }

  }

  // MARK: - UITestFixtureBackend

  @MainActor
  private final class UITestFixtureBackend: RelayControlBackend {
    private let isTunnelProvisioned: Bool
    private let config = TunnelConfigSummary(
      id: UITestFixture.fixtureConfigIdentifier,
      name: "Fixture Config",
      createdAt: UITestFixture.fixtureConfigCreationDate
    )

    init(isTunnelProvisioned: Bool) {
      self.isTunnelProvisioned = isTunnelProvisioned
    }

    func start() async {
      await Task.yield()
    }

    func sample() async -> RelayStatusSample? {
      await Task.yield()
      return RelayStatusSample(snapshot: fixtureSnapshot)
    }

    func setRouting(enabled _: Bool) async {
      await Task.yield()
    }

    func selectPeer(id _: String) async {
      await Task.yield()
    }

    func selectEgressPeer(id _: String) async {
      await Task.yield()
    }

    #if targetEnvironment(macCatalyst)
      var usesEgressRoster: Bool {
        true
      }

      func installTunnel(configURL _: URL) async {
        await Task.yield()
      }

      func loadConfigText(id _: UUID) async -> String? {
        await Task.yield()
        return "[Interface]\nAddress = 10.0.0.2/32"
      }

      func importConfig(url _: URL, name _: String) async {
        await Task.yield()
      }

      func importConfig(name _: String, text _: String) async {
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
    #else
      func tunnelProvisioned() async -> Bool {
        await Task.yield()
        return isTunnelProvisioned
      }
    #endif

    private var fixtureSnapshot: TunnelDaemonStatusSnapshot {
      #if targetEnvironment(macCatalyst)
        return TunnelDaemonStatusSnapshot(
          running: true,
          peerState: .wireGuardConfigured,
          connectedPeerName: "Fixture iPhone",
          connectedPeers: [
            ConnectedPeer(id: "fixture-phone", name: "Fixture iPhone", isSelected: true)
          ],
          configLibrary: [config],
          activeConfigID: config.id
        )
      #else
        let peerState: TunnelPeerState
        let connectedPeerName: String?
        if isTunnelProvisioned {
          peerState = .wireGuardConfigured
          connectedPeerName = "Fixture Mac"
        } else {
          peerState = .notSelected
          connectedPeerName = nil
        }
        return TunnelDaemonStatusSnapshot(
          running: true,
          peerState: peerState,
          connectedPeerName: connectedPeerName
        )
      #endif
    }
  }

  #if targetEnvironment(macCatalyst)
    extension UITestFixtureBackend: ConfigLibraryBackend {}
  #else
    extension UITestFixtureBackend: PhoneTunnelProvisioningBackend {}
  #endif

#endif

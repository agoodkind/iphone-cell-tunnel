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
    private static let setupArgument = "--cell-tunnel-ui-test-setup"
    private static let vpnDisabledArgument = "--cell-tunnel-ui-test-vpn-disabled"
    private static let approvalRequiredEnvironment =
      "CELL_TUNNEL_UI_TEST_APPROVAL_REQUIRED"
    private static let defaultsSuiteName = "CellTunnelPhoneUITests"

    static var isEnabled: Bool {
      let arguments = ProcessInfo.processInfo.arguments
      return arguments.contains(provisionedArgument) || requiresApproval || showsSetup
        || showsVPNDisabled
    }

    /// Whether to report the saved VPN profile as switched off, so a UI test can drive
    /// the re-enable screen.
    private static var showsVPNDisabled: Bool {
      ProcessInfo.processInfo.arguments.contains(vpnDisabledArgument)
    }

    /// Whether to render the first-run setup screen instead of the dashboard, so a UI
    /// test can drive the setup screen's import action.
    private static var showsSetup: Bool {
      ProcessInfo.processInfo.arguments.contains(setupArgument)
    }

    @MainActor static func makeRelayController() -> RelayController {
      let backend = UITestFixtureBackend(
        isTunnelProvisioned: !requiresApproval,
        showsSetup: showsSetup,
        showsVPNDisabled: showsVPNDisabled)
      #if targetEnvironment(macCatalyst)
        return RelayController(
          backend: backend,
          lifetimeStore: LifetimeDataStore(suiteName: defaultsSuiteName),
          installState: InstallationState()
        )
      #else
        return RelayController(
          backend: backend,
          lifetimeStore: LifetimeDataStore(suiteName: defaultsSuiteName)
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
    private var configText = "[Interface]\nAddress = 10.0.0.2/32"
    private let showsSetup: Bool
    private let showsVPNDisabled: Bool
    private let config = TunnelConfigSummary(
      id: UITestFixture.fixtureConfigIdentifier,
      name: "Fixture Config",
      createdAt: UITestFixture.fixtureConfigCreationDate
    )

    init(isTunnelProvisioned: Bool, showsSetup: Bool, showsVPNDisabled: Bool) {
      self.isTunnelProvisioned = isTunnelProvisioned
      self.showsSetup = showsSetup
      self.showsVPNDisabled = showsVPNDisabled
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
        return configText
      }

      func importConfig(url _: URL, name _: String) async {
        await Task.yield()
      }

      func importConfig(name _: String, text _: String, activate _: Bool) async -> UUID? {
        await Task.yield()
        return nil
      }

      func activateConfig(id _: UUID) async {
        await Task.yield()
      }

      func saveConfigEdit(id _: UUID, text: String) async {
        await Task.yield()
        configText = text
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
        if showsSetup {
          return TunnelDaemonStatusSnapshot(
            running: true,
            peerState: .notSelected,
            configLibrary: []
          )
        }
        // A dialed-in iPhone and an active config, so every input the routing switch
        // needs is present and only the switched-off profile withholds it. Without the
        // peer the switch would be hidden anyway and the test could not tell the
        // difference.
        if showsVPNDisabled {
          return TunnelDaemonStatusSnapshot(
            running: false,
            peerState: .wireGuardConfigured,
            connectedPeerName: "Fixture iPhone",
            connectedPeers: [
              ConnectedPeer(id: "fixture-phone", name: "Fixture iPhone", isSelected: true)
            ],
            configLibrary: [config],
            activeConfigID: config.id,
            vpnProfileState: .disabled
          )
        }
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

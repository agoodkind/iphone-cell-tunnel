//
//  SetupScreen.swift
//  CellTunnelPhone
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-06-05.
//  Copyright © 2026, all rights reserved.
//

#if targetEnvironment(macCatalyst)
  import CellTunnelCore
  import CellTunnelLog
  import SwiftUI
  import UniformTypeIdentifiers

  // MARK: - Constants

  private let setupLogger = CellTunnelLog.logger(category: .app)
  private let setupActionIdentifier = "cell-tunnel.setup-action"
  private let setupStepsIdentifier = "cell-tunnel.setup-steps"
  private let contentStackSpacing: CGFloat = 24
  private let contentMaxWidth: CGFloat = 480
  private let contentPadding: CGFloat = 32
  private let iconPointSize: CGFloat = 48
  private let buttonMinWidth: CGFloat = 200
  private let stepSpacing: CGFloat = 10
  private let stepNumberSpacing: CGFloat = 10
  private let stepBlockPadding: CGFloat = 16
  private let stepBackgroundOpacity: CGFloat = 0.5
  private let stepBlockCornerRadius: CGFloat = 10
  private let stepBlockShape = RoundedRectangle(
    cornerRadius: stepBlockCornerRadius, style: .continuous)
  private let configContentTypes: [UTType] = [
    UTType(filenameExtension: "conf") ?? .plainText,
    .plainText,
    .data,
  ]

  // MARK: - SetupScreen

  /// The full-tier setup screen, shared by the iPhone and the Mac. It shows a single SF
  /// Symbol, a title, a one-sentence subtitle, and one primary button driven by the
  /// status's offered action: install the agent or import a configuration. The reduced
  /// dashboards render every other state, so this view only handles the two setup
  /// states.
  struct SetupScreen: View {
    @Environment(RelayController.self) private var controller
    @State private var isImportingConfig = false

    private var model: RelayScreenModel {
      RelayScreenModel(controller: controller)
    }

    // MARK: - Body

    var body: some View {
      VStack(spacing: contentStackSpacing) {
        icon
        title
        subtitle
        steps
        actionButton
        errorMessage
      }
      .frame(maxWidth: contentMaxWidth)
      .padding(contentPadding)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .fileImporter(
        isPresented: $isImportingConfig,
        allowedContentTypes: configContentTypes,
        allowsMultipleSelection: false
      ) { result in
        handleImport(result)
      }
      .animation(.default, value: model.status)
    }

    // MARK: - Content

    @ViewBuilder private var icon: some View {
      if let action = model.heroAction {
        Image(systemName: action.systemImage)
          .font(.system(size: iconPointSize, weight: .light))
          .foregroundStyle(.tint)
      }
    }

    private var title: some View {
      Text(titleText)
        .font(.title.weight(.semibold))
        .multilineTextAlignment(.center)
    }

    private var subtitle: some View {
      Text(subtitleText)
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The ordered steps, left-aligned in their own grouped block so the numbers line
    /// up and each step reads as one short instruction rather than a wall of centered
    /// text. Nothing renders for a state that has no steps.
    @ViewBuilder private var steps: some View {
      let orderedSteps = setupSteps
      if !orderedSteps.isEmpty {
        VStack(alignment: .leading, spacing: stepSpacing) {
          ForEach(Array(orderedSteps.enumerated()), id: \.offset) { index, step in
            stepRow(number: index + 1, text: step)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(stepBlockPadding)
        .background(.quaternary.opacity(stepBackgroundOpacity), in: stepBlockShape)
        // Group the rows into one element so the block is addressable as a whole,
        // both for VoiceOver and for the test that asserts the steps are shown.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(stepsAccessibilityLabel))
        .accessibilityIdentifier(setupStepsIdentifier)
      }
    }

    private var stepsAccessibilityLabel: String {
      "Steps to turn the VPN back on"
    }

    private func stepRow(number: Int, text: String) -> some View {
      HStack(alignment: .firstTextBaseline, spacing: stepNumberSpacing) {
        Text("\(number).")
          .font(.body.weight(.semibold))
          .foregroundStyle(.tint)
          .monospacedDigit()
        Text(text)
          .font(.body)
          .fixedSize(horizontal: false, vertical: true)
      }
    }

    @ViewBuilder private var actionButton: some View {
      if model.heroAction != nil {
        Button(model.setupActionTitle) {
          performAction()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .frame(minWidth: buttonMinWidth)
        .accessibilityIdentifier(setupActionIdentifier)
      }
    }

    @ViewBuilder private var errorMessage: some View {
      if let message = model.errorMessage {
        Text(message)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
    }

    // MARK: - Actions

    private func performAction() {
      switch model.heroAction {
      case .enableVPN:
        model.openVPNSettings()
      case .importConfig:
        isImportingConfig = true
      case .installAgent:
        model.installAgent()
      case .openLocalNetworkSettings:
        model.openLocalNetworkSettings()
      case .retry, .selectPeer, .none:
        break
      }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
      switch result {
      case .success(let urls):
        guard let url = urls.first else {
          return
        }
        model.installTunnel(configURL: url)
      case .failure(let error):
        setupLogger.error(
          """
          setup config import failed \
          details=\(String(describing: error), privacy: .public) recovery=keep-setup-screen
          """
        )
      }
    }

    // MARK: - Copy

    private var titleText: String {
      switch model.status {
      case .noAgent:
        return model.isAwaitingBackgroundApproval
          ? "Approve Cell Tunnel in Login Items" : "Finish setting up"
      case .noConfigImported:
        return "Import a tunnel configuration"
      case .notDiscoverable:
        return "This Mac cannot be found"
      case .vpnProfileDisabled:
        return "Turn the VPN back on"
      case .connecting, .failed, .noActiveConfig, .noPeerSelected, .noPeersFound,
        .notProvisioned, .readyToRoute, .routing:
        return model.status.label
      }
    }

    private var subtitleText: String {
      switch model.status {
      case .noAgent:
        return model.isAwaitingBackgroundApproval
          ? "Turn Cell Tunnel on in Login Items to let it run in the background."
          : "Cell Tunnel keeps running after you close this window, so it can route "
            + "traffic whenever your iPhone is nearby."
      case .noConfigImported:
        return "Choose a WireGuard configuration file to set up the tunnel."
      case .notDiscoverable:
        return "Your iPhone finds this Mac over the local network, and Cell Tunnel is "
          + "not allowed to use it yet."
      case .vpnProfileDisabled:
        return "Cell Tunnel is switched off in System Settings, so it cannot "
          + "route traffic until you turn it back on."
      case .connecting, .failed, .noActiveConfig, .noPeerSelected, .noPeersFound,
        .notProvisioned, .readyToRoute, .routing:
        return ""
      }
    }

    /// What to do in System Settings, for a state the app cannot resolve on the
    /// user's behalf. The steps stay on screen while System Settings is in front, so
    /// they are readable at the moment they are followed, and they name the row by
    /// the same title the system shows. They describe only this task, since the
    /// button already covers opening System Settings and which pane it lands on
    /// varies.
    private var setupSteps: [String] {
      switch model.status {
      case .notDiscoverable:
        return [
          "Click Local Network in the sidebar.",
          "Turn on Cell Tunnel.",
        ]
      case .vpnProfileDisabled:
        return [
          "Click VPN in the sidebar.",
          "Turn on Cell Tunnel.",
        ]
      case .connecting, .failed, .noActiveConfig, .noAgent, .noConfigImported,
        .noPeerSelected, .noPeersFound, .notProvisioned, .readyToRoute, .routing:
        return []
      }
    }
  }

  // MARK: - Preview

  #Preview {
    SetupScreen()
      .environment(
        RelayController(
          backend: PreviewRelayBackend(),
          lifetimeStore: LifetimeDataStore()
        )
      )
  }

#endif

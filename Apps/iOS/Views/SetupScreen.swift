//
//  SetupScreen.swift
//  CellTunnelPhone
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-06-05.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Constants

private let setupLogger = CellTunnelLog.logger(category: .app)
private let contentStackSpacing: CGFloat = 24
private let contentMaxWidth: CGFloat = 480
private let contentPadding: CGFloat = 32
private let iconPointSize: CGFloat = 48
private let buttonMinWidth: CGFloat = 200
private let configContentTypes: [UTType] = [
  UTType(filenameExtension: "conf") ?? .plainText,
  .plainText,
  .data,
]

// MARK: - SetupScreen

/// The full-tier setup screen, shared by the iPhone and the Mac. It shows a single SF
/// Symbol, a title, a one-sentence subtitle, and one primary button driven by the
/// status's offered action: install the agent or import and install the tunnel. The
/// reduced dashboards render every other state, so this view only handles the two
/// install states.
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

  @ViewBuilder private var actionButton: some View {
    if model.heroAction != nil {
      Button(model.setupActionTitle) {
        performAction()
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .frame(minWidth: buttonMinWidth)
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
    case .installAgent:
      model.installAgent()
    case .installTunnel:
      isImportingConfig = true
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
      return "Install the background agent"
    case .noTunnelInstalled:
      return "Install the tunnel"
    case .error, .noPeerSelected, .noPeersFound, .passthrough, .readyToStartRelay,
      .relayEnabled:
      return model.status.label
    }
  }

  private var subtitleText: String {
    switch model.status {
    case .noAgent:
      return "The agent runs in the background so the relay keeps working "
        + "after the app closes."
    case .noTunnelInstalled:
      return "Import a tunnel configuration to set up the relay."
    case .error, .noPeerSelected, .noPeersFound, .passthrough, .readyToStartRelay,
      .relayEnabled:
      return ""
    }
  }
}

// MARK: - Preview

#Preview {
  SetupScreen()
    .environment(
      RelayController(
        backend: PreviewRelayBackend(),
        throughput: ThroughputCalculator(),
        lifetimeStore: LifetimeDataStore()
      )
    )
}

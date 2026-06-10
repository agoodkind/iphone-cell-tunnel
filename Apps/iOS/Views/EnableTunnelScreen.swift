//
//  EnableTunnelScreen.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-09.
//  Copyright © 2026, all rights reserved.
//

import SwiftUI

// MARK: - Constants

private let contentStackSpacing: CGFloat = 24
private let contentMaxWidth: CGFloat = 480
private let contentPadding: CGFloat = 32
private let iconPointSize: CGFloat = 48
private let buttonMinWidth: CGFloat = 200

// MARK: - EnableTunnelScreen

/// The iPhone setup screen for approving the VPN configuration. The iPhone needs
/// only an approved VPN configuration, no imported file, so this screen explains
/// the VPN and the single button opens the iOS approval sheet by starting the
/// session, which saves the configuration.
struct EnableTunnelScreen: View {
  @Environment(RelayController.self) private var controller

  private var model: RelayScreenModel {
    RelayScreenModel(controller: controller)
  }

  // MARK: - Body

  var body: some View {
    VStack(spacing: contentStackSpacing) {
      icon
      title
      bodyText
      permissionLine
      actionButton
    }
    .frame(maxWidth: contentMaxWidth)
    .padding(contentPadding)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Content

  private var icon: some View {
    Image(systemName: "network.badge.shield.half.filled")
      .font(.system(size: iconPointSize, weight: .light))
      .foregroundStyle(.tint)
  }

  private var title: some View {
    Text("Set Up VPN")
      .font(.title.weight(.semibold))
      .multilineTextAlignment(.center)
  }

  private var bodyText: some View {
    Text(
      "Cell Tunnel relays your Mac's internet traffic through this iPhone. "
        + "To do this, it adds a VPN configuration that you approve once."
    )
    .font(.body)
    .foregroundStyle(.secondary)
    .multilineTextAlignment(.center)
    .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder private var permissionLine: some View {
    if model.errorMessage != nil {
      Text("Cell Tunnel needs your permission to add the VPN configuration.")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var actionButton: some View {
    Button("Continue") {
      model.startSession()
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.large)
    .frame(minWidth: buttonMinWidth)
  }
}

// MARK: - Preview

#Preview {
  EnableTunnelScreen()
    .environment(
      RelayController(
        backend: PreviewRelayBackend(),
        throughput: ThroughputCalculator(),
        lifetimeStore: LifetimeDataStore()
      )
    )
}

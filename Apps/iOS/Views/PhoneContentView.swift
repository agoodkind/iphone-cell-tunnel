//
//  PhoneContentView.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-23.
//  Copyright © 2026, all rights reserved.
//

import SwiftUI

// MARK: - PhoneContentView

/// The root content view. Both platforms read the same `RelayController` from the
/// environment. The Mac keeps the shared guided setup for agent install and config
/// import, then shows the Mac dashboard. The iPhone shows the VPN setup screen
/// whenever no tunnel configuration exists, and the dashboard otherwise.
struct PhoneContentView: View {
  @Environment(RelayController.self) private var controller

  private var model: RelayScreenModel {
    RelayScreenModel(controller: controller)
  }

  var body: some View {
    #if targetEnvironment(macCatalyst)
      switch model.uiTier {
      case .full:
        SetupScreen()
      case .reduced:
        MacStatusScreen()
      }
    #else
      if !model.isTunnelInstalled {
        EnableTunnelScreen()
      } else {
        RelayStatusScreen()
      }
    #endif
  }
}

#Preview {
  PhoneContentView()
    .environment(
      RelayController(
        backend: PreviewRelayBackend(),
        throughput: ThroughputCalculator(),
        lifetimeStore: LifetimeDataStore()
      )
    )
}

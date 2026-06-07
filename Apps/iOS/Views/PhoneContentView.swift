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
/// environment, and the screen branches on the status's UI tier: the two setup states
/// take over with the shared `SetupScreen`, and every other state shows the reduced
/// dashboard, which is the list-form `RelayStatusScreen` on the iPhone and the
/// sidebar-and-dashboard `MacStatusScreen` on the Mac.
struct PhoneContentView: View {
  @Environment(RelayController.self) private var controller

  private var model: RelayScreenModel {
    RelayScreenModel(controller: controller)
  }

  var body: some View {
    switch model.uiTier {
    case .full:
      SetupScreen()
    case .reduced:
      reducedDashboard
    }
  }

  @ViewBuilder private var reducedDashboard: some View {
    #if targetEnvironment(macCatalyst)
      MacStatusScreen()
    #else
      RelayStatusScreen()
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

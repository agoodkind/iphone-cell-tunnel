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
/// environment; only the layout diverges. The iPhone renders the list-form
/// `RelayStatusScreen`, and the Mac renders the sidebar-and-dashboard
/// `MacStatusScreen`.
struct PhoneContentView: View {
    var body: some View {
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

//
//  PhoneContentView.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-23.
//  Copyright © 2026, all rights reserved.
//

import SwiftUI

// MARK: - PhoneContentView

/// The root content view for both platforms. It hosts the one shared status screen
/// and hands it the `RelayController` the app owns, so the iPhone and the Mac render
/// the same screen from the same source.
struct PhoneContentView: View {
    let controller: RelayController

    var body: some View {
        RelayStatusScreen(controller: controller)
    }
}

#Preview {
    PhoneContentView(controller: RelayController(backend: PreviewRelayBackend()))
}

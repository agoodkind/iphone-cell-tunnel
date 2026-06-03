//
//  PreviewRelayBackend.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-02.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore

// MARK: - PreviewRelayBackend

/// A no-op backend so the SwiftUI previews can build a `RelayController` without a
/// platform session. It answers no status, which renders the not-set-up state. The
/// yields keep the no-op functions real suspension points for the async contract.
@MainActor
final class PreviewRelayBackend: RelayControlBackend {
    func start() async {
        await Task.yield()
    }

    func stop() async {
        await Task.yield()
    }

    func sample() async -> RelayStatusSample? {
        await Task.yield()
        return nil
    }
}

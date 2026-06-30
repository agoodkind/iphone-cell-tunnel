//
//  PreviewRelayBackend.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-02.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation

// MARK: - PreviewRelayBackend

/// A no-op backend so the SwiftUI previews can build a `RelayController` without a
/// platform session. It answers no status, which renders the no-peers state. The
/// yields keep the no-op functions real suspension points for the async contract.
@MainActor
final class PreviewRelayBackend: RelayControlBackend {
  func start() async {
    await Task.yield()
  }

  /// Previews have no platform setup gate, so launch gating always proceeds.
  func tunnelProvisioned() async -> Bool {
    await Task.yield()
    return true
  }

  func sample() async -> RelayStatusSample? {
    await Task.yield()
    return nil
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

  func installTunnel(configURL _: URL) async {
    await Task.yield()
  }

  // The preview backend hosts no config library, so it takes the shared no-op config-op
  // defaults from RelayControlBackend.
}

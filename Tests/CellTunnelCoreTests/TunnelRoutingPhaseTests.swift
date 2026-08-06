//
//  TunnelRoutingPhaseTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-03.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import Testing

// MARK: - TunnelRoutingPhaseTests

/// Covers the phase the daemon publishes, which replaced a countdown a client ran only
/// while it happened to be reading status.
struct TunnelRoutingPhaseTests {
  @Test func offWithNothingInstalledIsIdle() {
    let phase = TunnelRoutingPhase.resolve(isRoutingEnabled: false, areRoutesInstalled: false)

    #expect(phase == .idle)
  }

  /// Asked for, not carrying traffic yet. This is what a person sees a spinner for.
  @Test func onBeforeTheRoutesLandIsConnecting() {
    let phase = TunnelRoutingPhase.resolve(isRoutingEnabled: true, areRoutesInstalled: false)

    #expect(phase == .connecting)
  }

  @Test func onWithRoutesInstalledIsRouting() {
    let phase = TunnelRoutingPhase.resolve(isRoutingEnabled: true, areRoutesInstalled: true)

    #expect(phase == .routing)
  }

  /// Turned off while the routes are still there. Reporting this as off would show a
  /// switch that says nothing is routing while traffic is still going through.
  @Test func offWhileRoutesRemainIsStopping() {
    let phase = TunnelRoutingPhase.resolve(isRoutingEnabled: false, areRoutesInstalled: true)

    #expect(phase == .stopping)
  }

  @Test func travelsOnTheWire() throws {
    let snapshot = TunnelDaemonStatusSnapshot(routingPhase: .connecting)

    let encoded = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(TunnelDaemonStatusSnapshot.self, from: encoded)

    #expect(decoded.routingPhase == .connecting)
  }

  /// A producer that predates the field says nothing rather than a wrong phase, which a
  /// reader tells apart from a real one.
  @Test func absentFromAnOlderProducer() {
    #expect(TunnelDaemonStatusSnapshot().routingPhase == nil)
  }
}

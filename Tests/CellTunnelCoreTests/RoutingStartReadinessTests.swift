//
//  RoutingStartReadinessTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-01.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import Testing

// MARK: - RoutingStartReadinessTests

/// Covers the one rule for whether routing may start: the rule the daemon enforces and
/// the rule the switch is drawn from. The missing-iPhone case is the one a client used
/// to miss, which is what produced a live switch that was then refused.
struct RoutingStartReadinessTests {
  @Test func readyWithActiveConfigAndSelectedPeer() {
    let readiness = routingStartReadiness(hasActiveConfig: true, hasSelectedPeer: true)

    #expect(readiness == .ready)
    #expect(readiness.canProceed)
    #expect(readiness.rejectionErrorCode == nil)
    #expect(readiness.rejectionMessage == nil)
  }

  @Test func noActiveConfigRejectsWithConfigSelectionRequired() {
    let readiness = routingStartReadiness(hasActiveConfig: false, hasSelectedPeer: true)

    #expect(readiness == .noActiveConfig)
    #expect(readiness.canProceed == false)
    #expect(readiness.rejectionErrorCode == .configSelectionRequired)
    #expect(readiness.rejectionMessage == noActiveConfigSelectedMessage)
  }

  @Test func noSelectedPeerRejectsWithRelaySelectionRequired() {
    // The case a client did not check. Its switch was live here and the request failed.
    let readiness = routingStartReadiness(hasActiveConfig: true, hasSelectedPeer: false)

    #expect(readiness == .noSelectedPeer)
    #expect(readiness.canProceed == false)
    #expect(readiness.rejectionErrorCode == .relaySelectionRequired)
    #expect(readiness.rejectionMessage == noSelectedPeerConnectionMessage)
  }

  @Test func missingConfigOutranksMissingPeer() {
    // With neither present, choosing a configuration is the step a person can take here,
    // so that is the reason shown rather than one they cannot act on yet.
    let readiness = routingStartReadiness(hasActiveConfig: false, hasSelectedPeer: false)

    #expect(readiness == .noActiveConfig)
  }

  @Test func travelsOnTheWire() throws {
    let snapshot = TunnelDaemonStatusSnapshot(routingStartReadiness: .noSelectedPeer)
    let encoded = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(TunnelDaemonStatusSnapshot.self, from: encoded)

    #expect(decoded.routingStartReadiness == .noSelectedPeer)
  }

  /// A producer that predates the field says nothing rather than a wrong answer, which a
  /// reader tells apart from a real verdict.
  @Test func absentFromAnOlderProducer() {
    #expect(TunnelDaemonStatusSnapshot().routingStartReadiness == nil)
  }
}

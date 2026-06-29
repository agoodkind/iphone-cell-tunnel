//
//  RoutingEnablePreconditionTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-28.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Testing

// MARK: - RoutingEnablePreconditionTests

/// Covers the shared routing-enable decision both the live switch path (`enableRouting`)
/// and the request path (`handleSetRoutingEnabled`) consult. A hosted relay proceeds
/// without a config, a resolvable config proceeds to start, and a missing config rejects
/// with `configSelectionRequired` so the rejection code and message cannot drift between
/// the two entry points.
struct RoutingEnablePreconditionTests {
  // MARK: - Hosted relay needs no config

  @Test func hostedRelayProceedsWithoutConfig() {
    let decision = routingEnablePrecondition(
      relayHosted: true,
      hasResolvableActiveConfig: false
    )

    #expect(decision == .relayHostedReady)
    #expect(decision.canProceed)
    #expect(decision.rejectionErrorCode == nil)
  }

  @Test func hostedRelayProceedsEvenWithConfig() {
    let decision = routingEnablePrecondition(
      relayHosted: true,
      hasResolvableActiveConfig: true
    )

    #expect(decision == .relayHostedReady)
    #expect(decision.canProceed)
  }

  // MARK: - Resolvable config proceeds to start

  @Test func resolvableConfigProceedsToStart() {
    let decision = routingEnablePrecondition(
      relayHosted: false,
      hasResolvableActiveConfig: true
    )

    #expect(decision == .activeConfigReady)
    #expect(decision.canProceed)
    #expect(decision.rejectionErrorCode == nil)
  }

  // MARK: - Missing config rejects with the shared code and message

  @Test func missingConfigRejectsWithConfigSelectionRequired() {
    let decision = routingEnablePrecondition(
      relayHosted: false,
      hasResolvableActiveConfig: false
    )

    #expect(decision == .noActiveConfig)
    #expect(!decision.canProceed)
    #expect(decision.rejectionErrorCode == .configSelectionRequired)
  }

  @Test func noActiveConfigMessageIsStable() {
    // The live path sets this as lastStartError and the request path returns it in the
    // failure response; pinning it guards the two against drifting apart.
    #expect(noActiveConfigSelectedMessage == "no active config selected")
  }
}

//
//  RelayLivenessTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import Testing

@testable import CellTunnelCore

@Suite("Relay liveness")
struct RelayLivenessTests {
  /// A single missed reply is a stall, not a death. Withdrawing routes on one
  /// miss would drop a working tunnel every time the agent is briefly busy.
  @Test("one missed reply does not declare the agent gone")
  func oneMissIsNotGone() {
    var liveness = RelayLiveness(missedRepliesBeforeGone: 3)
    #expect(liveness.recordMissedReply() == .unchanged)
  }

  @Test("the configured number of consecutive misses declares the agent gone")
  func enoughMissesDeclareGone() {
    var liveness = RelayLiveness(missedRepliesBeforeGone: 3)
    #expect(liveness.recordMissedReply() == .unchanged)
    #expect(liveness.recordMissedReply() == .unchanged)
    #expect(liveness.recordMissedReply() == .gone)
  }

  /// The verdict reports the transition, not the state, so the caller withdraws
  /// routes once rather than on every tick after the agent dies.
  @Test("staying gone reports no further change")
  func goneIsReportedOnce() {
    var liveness = RelayLiveness(missedRepliesBeforeGone: 2)
    _ = liveness.recordMissedReply()
    #expect(liveness.recordMissedReply() == .gone)
    #expect(liveness.recordMissedReply() == .unchanged)
  }

  /// A reply inside the window clears the count, so an agent that stalls and
  /// recovers keeps its routes.
  @Test("a reply clears the miss count")
  func replyClearsTheCount() {
    var liveness = RelayLiveness(missedRepliesBeforeGone: 3)
    _ = liveness.recordMissedReply()
    _ = liveness.recordMissedReply()
    #expect(liveness.recordReply() == .unchanged)
    #expect(liveness.recordMissedReply() == .unchanged)
    #expect(liveness.recordMissedReply() == .unchanged)
    #expect(liveness.recordMissedReply() == .gone)
  }

  /// An agent that comes back reports the transition, so the caller can restore
  /// routes once rather than on every reply.
  @Test("a reply after being gone reports the agent live again")
  func replyAfterGoneReportsLive() {
    var liveness = RelayLiveness(missedRepliesBeforeGone: 1)
    #expect(liveness.recordMissedReply() == .gone)
    #expect(liveness.recordReply() == .live)
    #expect(liveness.recordReply() == .unchanged)
  }
}

//
//  AgentWorkTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import Testing

@testable import CellTunnelCore

@Suite("Agent idle countdown")
struct AgentWorkTests {
  private let idle: Double = 60
  private let advertising: Double = 900

  @Test("nothing in flight uses the short countdown")
  func idleUsesShortCountdown() {
    #expect(
      AgentWork.idle.idleCountdownSeconds(idle: idle, advertising: advertising) == idle)
  }

  /// Waiting for a phone sends no control requests, so a short countdown would
  /// terminate the agent mid-advertisement and leave the phone unable to find it.
  @Test("waiting for a phone uses the long countdown")
  func advertisingUsesLongCountdown() {
    #expect(
      AgentWork.advertising.idleCountdownSeconds(idle: idle, advertising: advertising)
        == advertising)
  }

  /// A hosted relay must never get the short countdown, because the agent owns the
  /// bridge in memory and the phone's UDP link surfaces no drop when it dies.
  @Test("hosting a relay never uses the short countdown")
  func hostingNeverUsesShortCountdown() {
    let hosting = AgentWork.hostingRelay.idleCountdownSeconds(
      idle: idle, advertising: advertising)
    #expect(hosting > idle)
    #expect(hosting == advertising)
  }

  /// Every case must yield a finite countdown, so no state can ask for a wait that
  /// never ends. This covers the length only. Whether a timer is actually armed,
  /// and whether the agent exits when one fires, are decided in the agent target
  /// and are not observable from here.
  @Test(
    "every state yields a finite countdown",
    arguments: [AgentWork.advertising, AgentWork.hostingRelay, AgentWork.idle]
  )
  func everyStateIsBounded(work: AgentWork) {
    let seconds = work.idleCountdownSeconds(idle: idle, advertising: advertising)
    #expect(seconds.isFinite)
    #expect(seconds > 0)
  }
}

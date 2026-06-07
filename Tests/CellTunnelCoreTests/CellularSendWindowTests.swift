//
//  CellularSendWindowTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-31.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import Testing

// MARK: - CellularSendWindowTests

struct CellularSendWindowTests {
  private let overTarget = CellularSendWindow.targetWaitMilliseconds * 10
  private let underTarget = CellularSendWindow.targetWaitMilliseconds / 10

  // MARK: - Direction

  @Test func waitAboveTargetShrinksAllowance() {
    var window = CellularSendWindow()
    let start = window.allowance
    for _ in 0..<20 {
      window.recordWait(milliseconds: overTarget, windowLimited: true)
    }

    #expect(window.allowance < start)
  }

  @Test func waitBelowTargetAndLimitedGrowsAllowance() {
    var window = CellularSendWindow()
    let start = window.allowance
    for _ in 0..<20 {
      window.recordWait(milliseconds: underTarget, windowLimited: true)
    }

    #expect(window.allowance > start)
  }

  // MARK: - The window-limited gate

  @Test func belowTargetButNotLimitedHolds() {
    var window = CellularSendWindow()
    let start = window.allowance
    for _ in 0..<50 {
      window.recordWait(milliseconds: underTarget, windowLimited: false)
    }

    // Not the bottleneck, so the allowance does not balloon during the lull.
    #expect(window.allowance == start)
  }

  @Test func aboveTargetShrinksEvenWhenNotLimited() {
    var window = CellularSendWindow()
    let start = window.allowance
    for _ in 0..<20 {
      window.recordWait(milliseconds: overTarget, windowLimited: false)
    }

    #expect(window.allowance < start)
  }

  // MARK: - Bounds

  @Test func allowanceClampsAtFloor() {
    var window = CellularSendWindow()
    for _ in 0..<2_000 {
      window.recordWait(milliseconds: overTarget, windowLimited: true)
    }

    #expect(window.allowance == CellularSendWindow.minAllowance)
  }

  @Test func allowanceClampsAtCeiling() {
    var window = CellularSendWindow()
    for _ in 0..<2_000 {
      window.recordWait(milliseconds: underTarget, windowLimited: true)
    }

    #expect(window.allowance == CellularSendWindow.maxAllowance)
  }
}

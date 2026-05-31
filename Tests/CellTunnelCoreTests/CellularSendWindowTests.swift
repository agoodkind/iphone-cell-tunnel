//
//  CellularSendWindowTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-31.
//  Copyright © 2026
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
            window.recordWait(milliseconds: overTarget)
        }

        #expect(window.allowance < start)
    }

    @Test func waitBelowTargetGrowsAllowance() {
        var window = CellularSendWindow()
        let start = window.allowance
        for _ in 0..<20 {
            window.recordWait(milliseconds: underTarget)
        }

        #expect(window.allowance > start)
    }

    // MARK: - Bounds

    @Test func allowanceClampsAtFloor() {
        var window = CellularSendWindow()
        for _ in 0..<2_000 {
            window.recordWait(milliseconds: overTarget)
        }

        #expect(window.allowance == CellularSendWindow.minAllowance)
    }

    @Test func allowanceClampsAtCeiling() {
        var window = CellularSendWindow()
        for _ in 0..<2_000 {
            window.recordWait(milliseconds: underTarget)
        }

        #expect(window.allowance == CellularSendWindow.maxAllowance)
    }

    // MARK: - Steady state

    @Test func steadyAtTargetHoldsThenGrowsSlowly() {
        var window = CellularSendWindow()
        let start = window.allowance
        // A wait exactly at the target is not above it, so the allowance grows by
        // one per sample rather than shrinking.
        for _ in 0..<5 {
            window.recordWait(milliseconds: CellularSendWindow.targetWaitMilliseconds)
        }

        #expect(window.allowance == start + 5)
    }
}

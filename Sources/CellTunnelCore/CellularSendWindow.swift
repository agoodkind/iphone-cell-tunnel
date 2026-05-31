//
//  CellularSendWindow.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-31.
//  Copyright © 2026
//

import Foundation

// MARK: - CellularSendWindow

/// Sizes how many datagrams the iPhone relay may have in flight on the cellular
/// socket, so the local send buffer stays short and upload latency under load
/// stays low. The relay hands a datagram to the socket and is told when the
/// operating system accepts it; the gap between the two is how long that datagram
/// waited in the send buffer. This type keeps a smoothed wait and the current
/// allowance, and on each measured wait it moves the allowance toward holding the
/// wait at a target: at or below the target it raises the allowance by one so the
/// uplink can fill, above the target it cuts the allowance by a fraction so the
/// buffer drains. The allowance stays between a floor that never idles the radio
/// and a ceiling that bounds a stall. It is pure and unit tested without Network;
/// the relay confines it to its serial queue.
public struct CellularSendWindow: Sendable, Equatable {
    // MARK: - Tunables

    /// The wait the controller holds the local send buffer at. The loaded-latency
    /// budget for the cellular send queue.
    public static let targetWaitMilliseconds = 10.0

    /// The fewest datagrams allowed in flight, so the radio is never left idle
    /// between datagrams and throughput does not collapse.
    public static let minAllowance = 4

    /// The most datagrams allowed in flight, so a stalled uplink cannot let the
    /// buffer grow without bound.
    public static let maxAllowance = 512

    /// The starting allowance before any wait is measured.
    public static let initialAllowance = 64

    /// The weight a new wait sample carries in the smoothed wait. Small, so a
    /// single spike does not move the controller.
    public static let smoothingWeight = 0.05

    /// The fraction the allowance is multiplied by on a sample above target. Close
    /// to one, so each cut is gentle and a sustained overshoot compounds them.
    public static let decreaseFactor = 0.98

    // MARK: - State

    public private(set) var allowance: Int
    public private(set) var smoothedWaitMilliseconds: Double
    private var hasSample: Bool

    public init() {
        allowance = Self.initialAllowance
        smoothedWaitMilliseconds = 0
        hasSample = false
    }

    // MARK: - Control

    /// Folds one measured send-buffer wait into the smoothed wait and moves the
    /// allowance toward holding the wait at the target.
    public mutating func recordWait(milliseconds: Double) {
        if hasSample {
            smoothedWaitMilliseconds =
                (1 - Self.smoothingWeight) * smoothedWaitMilliseconds
                + Self.smoothingWeight * milliseconds
        } else {
            smoothedWaitMilliseconds = milliseconds
            hasSample = true
        }
        if smoothedWaitMilliseconds > Self.targetWaitMilliseconds {
            allowance = max(Self.minAllowance, Int(Double(allowance) * Self.decreaseFactor))
        } else {
            allowance = min(Self.maxAllowance, allowance + 1)
        }
    }
}

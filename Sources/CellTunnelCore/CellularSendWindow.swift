//
//  CellularSendWindow.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-31.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - CellularSendWindow

/// Sizes how many datagrams the iPhone relay may have in flight on the cellular
/// socket, so the local send buffer stays short and upload latency under load
/// stays low. The relay hands a datagram to the socket and is told when the
/// operating system accepts it; the gap between the two is how long that datagram
/// waited in the send buffer. This type keeps a smoothed wait and the current
/// allowance, and on each measured wait it moves the allowance toward holding the
/// wait at a target. Above the target it cuts the allowance by a fraction so the
/// buffer drains. At or below the target it raises the allowance by one, but only
/// when the window was the bottleneck (the relay had more to send and the
/// allowance blocked it); when the relay is not filling the window the allowance
/// holds, so it does not balloon during a lull and overshoot when traffic resumes.
/// The allowance stays between a floor that never idles the radio and a ceiling
/// that bounds a stall. It is pure and unit tested without Network; the relay
/// confines it to its serial queue.
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
    public static let maxAllowance = 256

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
    /// allowance toward holding the wait at the target. `windowLimited` is whether
    /// the window was the bottleneck since the last sample: the allowance grows
    /// only when it was, so it does not balloon while the relay is not filling it.
    public mutating func recordWait(milliseconds: Double, windowLimited: Bool) {
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
        } else if windowLimited {
            allowance = min(Self.maxAllowance, allowance + 1)
        }
    }
}

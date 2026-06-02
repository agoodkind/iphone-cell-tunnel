//
//  PhoneControlClient+Reconnect.swift
//  CellTunnelPhoneTunnel
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .relay)
private let controlReconnectBackoffSeconds = 2

// MARK: - Reconnect

/// Re-arms discovery and the dial after the control link drops, so the iPhone
/// recovers the control channel on its own when the Mac tunnel restarts or the
/// link bounces. This is the control-plane half of redial-on-drop; the data
/// plane recovers through the transport manager.
extension PhoneControlClient {
    /// Schedules a single reconnect after a fixed backoff that bounds the retry
    /// rate. The fired handler is `@Sendable` so it stays off the main thread
    /// until it hops back, and `start` rebuilds the browser and redials whichever
    /// agent is advertising now.
    func scheduleReconnect() {
        guard isActive else {
            return
        }
        redialTimer?.cancel()
        logger.notice(
            """
            control client scheduling reconnect \
            backoffSeconds=\(controlReconnectBackoffSeconds, privacy: .public)
            """
        )
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(controlReconnectBackoffSeconds))
        timer.setEventHandler { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                guard let self, isActive else {
                    return
                }
                start()
            }
        }
        timer.resume()
        redialTimer = timer
    }
}

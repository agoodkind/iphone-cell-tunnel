//
//  WireGuardRelayBind.swift
//  CellTunnelTunnelProvider
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-27.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Synchronization
import WireGuardKit

private let logger = CellTunnelLog.logger(category: .relay)

final class WireGuardRelayBind: WireGuardRelayBindBridge, @unchecked Sendable {
    private let transport: RelayTransport
    private let metrics: RelayMetrics
    private let didLogFirstSend = Atomic<Bool>(false)

    init(transport: RelayTransport, metrics: RelayMetrics) {
        self.transport = transport
        self.metrics = metrics
    }

    deinit {
        transport.onReceive = nil
    }

    func send(data: Data, endpoint: String) {
        metrics.addDatagramsToServer()
        metrics.addBytesOut(UInt64(data.count))
        // Log the outbound boundary once, not per datagram: a single relaxed
        // atomic check stays off the lock and keeps the hot path free of logging.
        if didLogFirstSend.compareExchange(
            expected: false,
            desired: true,
            ordering: .relaxed
        ).exchanged {
            logger.notice(
                """
                relay bind first outbound datagram \
                endpoint=\(endpoint, privacy: .public) bytes=\(data.count, privacy: .public)
                """
            )
        }
        transport.send(data)
    }

    func attach(injector: @escaping (Data, String) -> Void) {
        // WireGuard installs the injector once before any traffic and replaces or
        // clears it only at lifecycle boundaries, so capture it directly in the
        // receive closure rather than guarding a shared field with a per-datagram
        // lock. The closure runs on RelayTransport's serial receive queue.
        let relayMetrics = self.metrics
        transport.onReceive = { datagram in
            relayMetrics.addDatagramsFromServer()
            relayMetrics.addBytesIn(UInt64(datagram.count))
            injector(datagram, Self.inboundEndpoint)
        }
        logger.notice("relay bind inbound injector attached")
    }

    func detach() {
        transport.onReceive = nil
        logger.notice("relay bind inbound injector detached")
    }

    // The peer endpoint string is informational because RelayTransport already
    // targets the iPhone relay; wireguard-go still needs a non-empty endpoint
    // string when injecting received datagrams so its bind layer accepts them.
    private static let inboundEndpoint = "0.0.0.0:0"
}

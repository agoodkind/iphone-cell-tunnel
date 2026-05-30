//
//  LocalLinkInterfaceResolver.swift
//  CellTunnelPhoneTunnel
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//
//  Copyright © 2026
//

import CellTunnelLog
import Foundation
import Network

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .relay)
private let localLinkResolverQueueLabel = "io.goodkind.celltunnel.localLinkResolver"

// MARK: - Local-link interface resolver

/// Resolves the wired interface the Mac reaches over the USB link so the relay
/// listeners can pin to it with `NWParameters.requiredInterface`. The resolver
/// runs one `NWPathMonitor`, logs every interface the provider can see, and
/// completes once with the first `.wiredEthernet` interface, or with `nil` when
/// the satisfied path exposes no wired interface or the bounded wait elapses.
final class LocalLinkInterfaceResolver: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: localLinkResolverQueueLabel)
    private let stateLock = NSLock()
    private var didComplete = false
    private var completion: (@Sendable (NWInterface?) -> Void)?

    // MARK: - Resolve

    /// Starts monitoring and calls `completion` once with the resolved wired
    /// interface or `nil`. `timeoutSeconds` bounds the wait when no satisfied
    /// path ever arrives, using `asyncAfter` rather than a sleep.
    func resolve(
        timeoutSeconds: Double,
        completion: @escaping @Sendable (NWInterface?) -> Void
    ) {
        self.completion = completion
        logger.notice(
            "local link resolve started timeoutSeconds=\(timeoutSeconds, privacy: .public)"
        )
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handle(path: path)
        }
        monitor.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
            self?.complete(with: nil, reason: "timeout")
        }
    }

    // MARK: - Path handling

    private func handle(path: NWPath) {
        for interface in path.availableInterfaces {
            logger.notice(
                """
                local link interface available name=\(interface.name, privacy: .public) \
                type=\(Self.describe(interface.type), privacy: .public)
                """
            )
        }
        if let wired = path.availableInterfaces.first(where: { $0.type == .wiredEthernet }) {
            complete(with: wired, reason: "wired-found")
            return
        }
        if path.status == .satisfied {
            complete(with: nil, reason: "satisfied-no-wired")
        }
    }

    private func complete(with interface: NWInterface?, reason: String) {
        stateLock.lock()
        if didComplete {
            stateLock.unlock()
            return
        }
        didComplete = true
        let pending = completion
        completion = nil
        stateLock.unlock()

        logger.notice(
            """
            local link resolve done reason=\(reason, privacy: .public) \
            interface=\(interface?.name ?? "none", privacy: .public)
            """
        )
        monitor.cancel()
        pending?(interface)
    }

    // MARK: - Rendering

    private static func describe(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .other:
            return "other"
        case .wifi:
            return "wifi"
        case .cellular:
            return "cellular"
        case .wiredEthernet:
            return "wiredEthernet"
        case .loopback:
            return "loopback"
        @unknown default:
            return "unknown"
        }
    }
}

//
//  AgentTunnelController+Start.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-29.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
@preconcurrency import NetworkExtension

private let logger = CellTunnelLog.logger(category: .daemon)
private let sessionConnectTimeoutSeconds = 30

extension AgentTunnelController {
    func loadAllManagers() async throws -> [NETunnelProviderManager] {
        try await NETunnelProviderManager.loadAllFromPreferences()
    }

    func resumeVoidContinuation(
        _ body: (@escaping @Sendable (Error?) -> Void) -> Void
    ) async throws {
        let _: Void = try await withCheckedThrowingContinuation { continuation in
            body { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            }
        }
    }

    // Resolve the relay service name the provider should target, from the agent's
    // warm browser: a still visible persisted selection, else the first device.
    // Handing the provider a concrete name lets the extension skip the slow first
    // service cold browse that makes the first start fail.
    func resolvedRelayServiceName() -> String? {
        let warmDevices = relayBrowser.snapshot()
        let persisted = RelaySelectionStore.selectedRelayServiceName()
        if let persisted, warmDevices.contains(where: { $0.serviceName == persisted }) {
            return persisted
        }
        return warmDevices.first?.serviceName
    }

    // start should report the real outcome, not a snapshot taken before the
    // provider has discovered the relay and connected. Wait for the connection to
    // reach connected, or give up after the timeout so a genuine discovery failure
    // still returns. Bounded so the CLI cannot hang.
    func waitForSessionConnected(on manager: NETunnelProviderManager) async {
        let connection = manager.connection
        if connection.status == .connected {
            return
        }
        await SessionConnectWaiter().wait(
            on: connection,
            timeoutSeconds: sessionConnectTimeoutSeconds
        )
    }

    func statusDescription(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid:
            return "invalid"
        case .disconnected:
            return "disconnected"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .reasserting:
            return "reasserting"
        case .disconnecting:
            return "disconnecting"
        @unknown default:
            return "unknown"
        }
    }

    func failure(from error: Error) -> AgentControlResponse {
        if let controllerError = error as? AgentTunnelControllerError {
            return failure(errorCode: controllerError.errorCode, message: controllerError.message)
        }
        return failure(errorCode: .internal, message: error.localizedDescription)
    }

    func failure(
        errorCode: TunnelControlErrorCode,
        message: String
    ) -> AgentControlResponse {
        AgentControlResponse(failure: AgentControlFailure(errorCode: errorCode, message: message))
    }
}

// Resolves once the VPN connection reports connected, or after a bounded timeout,
// using the status notification and a scheduled deadline rather than polling. The
// lock makes the single continuation resume exactly once across the observer and
// the timeout.
// MARK: - SessionConnectWaiter

private final class SessionConnectWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var observer: NSObjectProtocol?
    private var timeoutItem: DispatchWorkItem?

    func wait(on connection: NEVPNConnection, timeoutSeconds: Int) async {
        logger.notice("agent waiting for tunnel session to reach connected")
        await withCheckedContinuation { pending in
            lock.lock()
            continuation = pending
            lock.unlock()

            observer = NotificationCenter.default.addObserver(
                forName: .NEVPNStatusDidChange,
                object: connection,
                queue: nil
            ) { [weak self] _ in
                if connection.status == .connected {
                    self?.finish(reason: "connected")
                }
            }
            let item = DispatchWorkItem { [weak self] in
                self?.finish(reason: "timeout")
            }
            timeoutItem = item
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .seconds(timeoutSeconds),
                execute: item
            )
            if connection.status == .connected {
                finish(reason: "connected")
            }
        }
    }

    private func finish(reason: String) {
        lock.lock()
        let pending = continuation
        continuation = nil
        let activeObserver = observer
        observer = nil
        let timer = timeoutItem
        timeoutItem = nil
        lock.unlock()

        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
        timer?.cancel()
        guard let pending else {
            return
        }
        logger.notice(
            "agent tunnel session connect wait resolved reason=\(reason, privacy: .public)"
        )
        pending.resume()
    }
}

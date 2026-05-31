//
//  ProviderMessageContinuationBox.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-25.
//  Copyright © 2026
//

import CellTunnelCore
import Foundation

// MARK: - ProviderMessageContinuationBox

/// Resumes a provider-message continuation exactly once, whether the extension
/// replies, returns no payload, or the bounded timeout fires first.
final class ProviderMessageContinuationBox: @unchecked Sendable {
    private let continuation: CheckedContinuation<Data, Error>
    private let operationName: String
    private let lock = NSLock()
    private var finished = false

    init(continuation: CheckedContinuation<Data, Error>, operationName: String) {
        self.continuation = continuation
        self.operationName = operationName
    }

    func resume(with response: Data?) {
        guard let response else {
            resumeOnce(
                throwing: TunnelDaemonError.transportFailure(
                    "extension returned no payload for \(operationName)"
                )
            )
            return
        }
        resumeOnce(returning: response)
    }

    func scheduleTimeout(_ timeoutSeconds: Double) {
        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                self?.resumeOnce(
                    throwing: TunnelDaemonError.transportFailure("extension message timed out")
                )
            }
    }

    func resumeOnce(returning value: Data) {
        guard claim() else {
            return
        }
        continuation.resume(returning: value)
    }

    func resumeOnce(throwing error: Error) {
        guard claim() else {
            return
        }
        continuation.resume(throwing: error)
    }

    private func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished {
            return false
        }
        finished = true
        return true
    }
}

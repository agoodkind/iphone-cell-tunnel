import CellTunnelLog
import Foundation

private let logger = CellTunnelLog.logger(category: .daemon)

enum DiscoveryServiceWaiterError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "discovery service waiter timed out before any iPhone surfaced"
        }
    }
}

/// Resolves the first discovered relay, or, when a `preferredServiceName` is set,
/// the first discovered relay whose Bonjour service name matches that selection.
/// If the preferred relay never appears before the timeout fires, the waiter
/// falls back to any relay seen so far and logs the fallback once.
final class DiscoveryServiceWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private let preferredServiceName: String?
    private var continuation: CheckedContinuation<DiscoveredService, Error>?
    private var resolved = false
    private var timeoutTask: DispatchWorkItem?
    private var latestFallback: DiscoveredService?

    init(preferredServiceName: String? = nil) {
        self.preferredServiceName = preferredServiceName
    }

    func deliver(services: Set<DiscoveredService>) {
        guard let match = selectMatch(from: services) else {
            return
        }
        lock.lock()
        if resolved {
            lock.unlock()
            return
        }
        resolved = true
        let captured = continuation
        continuation = nil
        let cancelItem = timeoutTask
        timeoutTask = nil
        lock.unlock()

        cancelItem?.cancel()
        captured?.resume(returning: match)
        logger.notice(
            "discovery waiter delivering identifier=\(match.identifier, privacy: .public)"
        )
    }

    func scheduleTimeout(seconds: UInt64) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.failTimeout()
        }
        lock.lock()
        timeoutTask = workItem
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + .seconds(Int(seconds)), execute: workItem)
    }

    func waitForService() async throws -> DiscoveredService {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if resolved {
                lock.unlock()
                cont.resume(throwing: DiscoveryServiceWaiterError.timedOut)
                return
            }
            continuation = cont
            lock.unlock()
        }
    }

    // Returns the matching service to resolve with now, recording any seen
    // service as a timeout fallback when a preferred name is still unmatched.
    private func selectMatch(from services: Set<DiscoveredService>) -> DiscoveredService? {
        guard let anyService = services.first else {
            logger.notice("discovery waiter received empty service set")
            return nil
        }
        guard let preferredServiceName else {
            return anyService
        }
        let preferred = services.first { $0.serviceName == preferredServiceName }
        if let preferred {
            return preferred
        }
        lock.lock()
        latestFallback = anyService
        lock.unlock()
        return nil
    }

    private func failTimeout() {
        lock.lock()
        if resolved {
            lock.unlock()
            return
        }
        resolved = true
        let captured = continuation
        continuation = nil
        timeoutTask = nil
        let fallback = latestFallback
        lock.unlock()

        if let fallback {
            logger.notice(
                """
                discovery waiter preferred relay not found before timeout \
                recovery=fallback-to-first identifier=\(fallback.identifier, privacy: .public)
                """
            )
            captured?.resume(returning: fallback)
            return
        }
        captured?.resume(throwing: DiscoveryServiceWaiterError.timedOut)
        logger.notice("discovery waiter failed reason=timeout")
    }
}

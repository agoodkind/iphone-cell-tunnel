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

final class DiscoveryServiceWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DiscoveredService, Error>?
    private var resolved = false
    private var timeoutTask: DispatchWorkItem?

    func deliver(services: Set<DiscoveredService>) {
        guard let firstService = services.first else {
            logger.notice("discovery waiter received empty service set")
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
        captured?.resume(returning: firstService)
        logger.notice(
            "discovery waiter delivering identifier=\(firstService.identifier, privacy: .public)"
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

    func waitForFirstService() async throws -> DiscoveredService {
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
        lock.unlock()

        captured?.resume(throwing: DiscoveryServiceWaiterError.timedOut)
        logger.notice("discovery waiter failed reason=timeout")
    }
}

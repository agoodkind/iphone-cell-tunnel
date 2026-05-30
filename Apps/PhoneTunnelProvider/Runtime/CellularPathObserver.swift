import CellTunnelCore
import CellTunnelLog
import Foundation
import Network
import Synchronization

private let logger = CellTunnelLog.logger(category: .relay)

/// Runs the cellular `NWPathMonitor` on its own serial queue and holds the latest
/// `CellularPathSnapshot` behind a `Mutex` so the packet-tunnel provider can read
/// it for status reporting without hopping to the MainActor. The provider owns one
/// instance, starts it in `startTunnel`, and cancels it in `stopTunnel`. This
/// replaces the monitor that previously lived on `PhoneRelayController` in the app
/// target, which cannot run in the background extension.
final class CellularPathObserver: @unchecked Sendable {
    private let monitorQueue = DispatchQueue(label: "CellTunnelPhone.CellularMonitor")
    private let monitor = NWPathMonitor(requiredInterfaceType: .cellular)
    private let latestSnapshot = Mutex(CellularPathSnapshot())

    var snapshot: CellularPathSnapshot {
        latestSnapshot.withLock { $0 }
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else {
                return
            }
            let cellularInterface = path.availableInterfaces.first { interface in
                interface.type == .cellular
            }
            let snapshot = CellularPathSnapshot(
                isSatisfied: path.status == .satisfied,
                supportsIPv4: path.supportsIPv4,
                supportsIPv6: path.supportsIPv6,
                interfaceName: cellularInterface?.name,
                interfaceIndex: cellularInterface?.index
            )
            latestSnapshot.withLock { $0 = snapshot }
            logger.info(
                """
                cellular path updated satisfied=\(path.status == .satisfied, privacy: .public) \
                ipv4=\(path.supportsIPv4, privacy: .public) \
                ipv6=\(path.supportsIPv6, privacy: .public) \
                interface=\(cellularInterface?.name ?? "none", privacy: .public)
                """
            )
        }
        monitor.start(queue: monitorQueue)
        logger.info("cellular monitor started")
    }

    func stop() {
        monitor.cancel()
        latestSnapshot.withLock { $0 = CellularPathSnapshot() }
        logger.info("cellular monitor stopped")
    }
}

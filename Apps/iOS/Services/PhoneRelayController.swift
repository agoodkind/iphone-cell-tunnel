import CellTunnelCore
import CellTunnelLog
import Foundation
import Network
import Observation
import UIKit

private let logger = CellTunnelLog.logger(category: .relay)

@MainActor
@Observable
final class PhoneRelayController: @unchecked Sendable {
    private let monitorQueue = DispatchQueue(label: "CellTunnelPhone.CellularMonitor")
    private var cellularMonitor: NWPathMonitor?
    private let controlListener = PhoneControlListener()
    let forwarder = PhoneRelayForwarder()
    var throughputTask: Task<Void, Never>?
    var throughputBaseline = TunnelCounters()

    var isRunning = false
    var connectedPeerName: String?
    var cellularPath = CellularPathSnapshot()
    var counters = TunnelCounters()
    var uploadMbps: Double = 0
    var downloadMbps: Double = 0
    var lastError: String?
    var relayStateDescription = WireGuardDatagramRelayState.stopped.displayName

    func start() {
        guard !isRunning else {
            logger.debug("phone relay start ignored because relay is already running")
            return
        }

        isRunning = true
        lastError = nil
        UIApplication.shared.isIdleTimerDisabled = true
        logger.notice("phone relay starting")
        startCellularMonitor()
        configureForwarderCallbacks()
        let serviceName = UIDevice.current.name
        startControlListener()
        forwarder.startListener(port: resolvedRelayListenerPort(), serviceName: serviceName)
        startThroughputLoop()
    }

    private func configureForwarderCallbacks() {
        logger.notice("phone relay forwarder callbacks configured")
        forwarder.onStateChange = { state in
            Task { @MainActor [weak self] in
                self?.relayStateDescription = state.displayName
            }
        }
        forwarder.onError = { message in
            Task { @MainActor [weak self] in
                self?.lastError = message
            }
        }
        forwarder.onPeerChange = { name in
            Task { @MainActor [weak self] in
                self?.connectedPeerName = name
            }
        }
        forwarder.onListenerReady = { port in
            logger.notice("phone relay listener ready port=\(port ?? 0, privacy: .public)")
        }
    }

    func stop() {
        logger.notice("phone relay stopping")
        isRunning = false
        connectedPeerName = nil
        UIApplication.shared.isIdleTimerDisabled = false
        stopThroughputLoop()
        controlListener.stop()
        forwarder.stop()
        cellularMonitor?.cancel()
        cellularMonitor = nil
    }

    private func startControlListener() {
        let serviceName = UIDevice.current.name
        logger.notice(
            "phone control listener starting serviceName=\(serviceName, privacy: .public)"
        )
        controlListener.onSetServerEndpoint = { [weak self] endpoint in
            self?.applyServerEndpoint(endpoint)
        }
        controlListener.statusProvider = { [weak self] in
            self?.currentControlStatus() ?? RelayControlMessage.Status(hasCellularPath: false)
        }
        controlListener.start(preferredServiceName: serviceName)
    }

    private func applyServerEndpoint(_ endpoint: RelayEndpoint) {
        forwarder.setServerEndpoint(endpoint)
    }

    private func currentControlStatus() -> RelayControlMessage.Status {
        RelayControlMessage.Status(
            hasCellularPath: cellularPath.isSatisfied,
            cellularInterface: cellularPath.interfaceName,
            lastError: lastError,
            counters: counters
        )
    }
}

extension PhoneRelayController {
    private func startCellularMonitor() {
        let monitor = NWPathMonitor(requiredInterfaceType: .cellular)
        monitor.pathUpdateHandler = { [weak self] path in
            let cellularInterface = path.availableInterfaces.first { interface in
                interface.type == .cellular
            }

            Task { @MainActor [weak self] in
                self?.cellularPath = CellularPathSnapshot(
                    isSatisfied: path.status == .satisfied,
                    supportsIPv4: path.supportsIPv4,
                    supportsIPv6: path.supportsIPv6,
                    interfaceName: cellularInterface?.name,
                    interfaceIndex: cellularInterface?.index
                )
                logger.info(
                    """
                    cellular path updated satisfied=\(path.status == .satisfied, privacy: .public) \
                    ipv4=\(path.supportsIPv4, privacy: .public) \
                    ipv6=\(path.supportsIPv6, privacy: .public) \
                    interface=\(cellularInterface?.name ?? "none", privacy: .public)
                    """
                )
            }
        }
        monitor.start(queue: monitorQueue)
        cellularMonitor = monitor
        logger.info("cellular monitor started")
    }

}

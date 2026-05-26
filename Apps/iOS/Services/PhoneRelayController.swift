import CellTunnelCore
import CellTunnelLog
import Foundation
import Network
import Observation
import UIKit

private let logger = CellTunnelLog.logger(category: .relay)
private let relayServiceType = "_cellrelay._udp"

@MainActor
@Observable
final class PhoneRelayController: @unchecked Sendable {
    private let monitorQueue = DispatchQueue(label: "CellTunnelPhone.CellularMonitor")
    private var cellularMonitor: NWPathMonitor?
    private var listener: NWListener?
    private let controlListener = PhoneControlListener()
    private var lastConfiguredEndpoint: RelayEndpoint?
    let wireGuardSession = WireGuardDatagramRelaySession()
    var throughputTask: Task<Void, Never>?
    var throughputBaseline = TunnelCounters()
    var currentMacConnection: NWConnection?

    var isRunning = false
    var isAdvertising = false
    var connectedPeerName: String?
    var advertisedServiceName: String?
    var listenerPort: UInt16?
    var controlListenerPort: UInt16?
    var cellularPath = CellularPathSnapshot()
    var counters = TunnelCounters()
    var lastError: String?

    var wireGuardRelayStateDescription: String {
        wireGuardSession.state.displayName
    }

    func toggle() {
        let wasRunning = isRunning
        logger.debug("phone relay toggle requested running=\(wasRunning, privacy: .public)")
        if isRunning {
            stop()
            return
        }

        start()
    }

    func updateListenerPort(_ port: UInt16) {
        let wasRunning = isRunning
        logger.notice(
            """
            phone relay listener port update requested \
            port=\(port, privacy: .public) wasRunning=\(wasRunning, privacy: .public)
            """
        )
        storeRelayListenerPort(port)
        if wasRunning {
            stop()
            start()
        }
    }

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
        wireGuardSession.prepareForHandshake()
        wireGuardSession.datagramHandler = { [weak self] datagram in
            Task { @MainActor [weak self] in
                self?.sendDatagramToMac(datagram)
            }
        }
        wireGuardSession.errorHandler = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.lastError = message
                logger.error("relay wireguard session reported error=\(message, privacy: .public)")
            }
        }
        startControlListener()
        startListener()
        startThroughputLoop()
    }

    func stop() {
        logger.notice("phone relay stopping")
        isRunning = false
        isAdvertising = false
        connectedPeerName = nil
        advertisedServiceName = nil
        listenerPort = nil
        controlListenerPort = nil
        lastConfiguredEndpoint = nil
        UIApplication.shared.isIdleTimerDisabled = false
        stopThroughputLoop()
        controlListener.stop()
        wireGuardSession.stop()
        cellularMonitor?.cancel()
        cellularMonitor = nil
        listener?.cancel()
        listener = nil
        currentMacConnection?.cancel()
        currentMacConnection = nil
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
        controlListenerPort = controlListener.listenerPort
    }

    private func applyServerEndpoint(_ endpoint: RelayEndpoint) {
        if let existing = lastConfiguredEndpoint, existing == endpoint {
            logger.notice("control endpoint update ignored (unchanged)")
            return
        }
        lastConfiguredEndpoint = endpoint
        if wireGuardSession.state != .stopped {
            wireGuardSession.stop()
            wireGuardSession.prepareForHandshake()
            wireGuardSession.datagramHandler = { [weak self] datagram in
                Task { @MainActor [weak self] in
                    self?.sendDatagramToMac(datagram)
                }
            }
            wireGuardSession.errorHandler = { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.lastError = message
                    logger.error(
                        "relay wireguard session reported error=\(message, privacy: .public)"
                    )
                }
            }
        }
        do {
            try wireGuardSession.start(endpoint: endpoint)
        } catch {
            lastError = error.localizedDescription
            logger.error(
                "wireguard session start failed error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func currentControlStatus() -> RelayControlMessage.Status {
        RelayControlMessage.Status(
            hasCellularPath: cellularPath.isSatisfied,
            cellularInterface: cellularPath.interfaceName,
            lastError: lastError
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

    private func startListener() {
        do {
            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters, on: resolvedRelayListenerPort())
            let serviceName = UIDevice.current.name
            advertisedServiceName = serviceName
            listener.service = NWListener.Service(name: serviceName, type: relayServiceType)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.accept(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handle(listenerState: state)
                }
            }
            listener.start(queue: monitorQueue)
            self.listener = listener
            isAdvertising = true
            logger.notice(
                """
                phone relay listener started service=\(relayServiceType, privacy: .public) \
                name=\(serviceName, privacy: .public)
                """
            )
        } catch {
            lastError = error.localizedDescription
            isAdvertising = false
            logger.error(
                "phone relay listener failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func accept(_ connection: NWConnection) {
        logger.notice(
            """
            phone relay accepting mac connection \
            endpoint=\(String(describing: connection.endpoint), privacy: .public)
            """
        )
        adoptMacConnection(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor [weak self, weak connection] in
                guard let connection else {
                    return
                }
                self?.handle(connectionState: state, connection: connection)
            }
        }
        connection.start(queue: monitorQueue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        logger.debug("phone relay receive scheduled")
        connection.receiveMessage { [weak self, weak connection] data, _, isComplete, error in
            if let error {
                Task { @MainActor [weak self, weak connection] in
                    guard let connection else {
                        return
                    }
                    self?.handleMacReceiveError(error, connection: connection)
                }
                return
            }

            if let data, !data.isEmpty {
                Task { @MainActor [weak self, weak connection] in
                    guard let connection else {
                        return
                    }
                    self?.handleDatagramFromMac(data, connection: connection)
                }
            }

            guard !isComplete, let connection else {
                return
            }

            Task { @MainActor [weak self, weak connection] in
                guard let connection else {
                    return
                }
                self?.receive(on: connection)
            }
        }
    }

    private func handleDatagramFromMac(_ data: Data, connection: NWConnection) {
        counters.relayBytesIn &+= UInt64(data.count)
        counters.wireGuardDatagramsFromMac &+= 1
        if currentMacConnection !== connection {
            adoptMacConnection(connection)
        }
        do {
            let datagram = try WireGuardDatagram(
                data: data,
                addressFamily: .ipv4
            )
            try wireGuardSession.sendToServer(datagram)
            counters.wireGuardDatagramsToServer &+= 1
        } catch {
            counters.droppedWireGuardDatagrams &+= 1
            lastError = error.localizedDescription
            logger.error(
                """
                relay datagram from mac dropped \
                error=\(error.localizedDescription, privacy: .public)
                """
            )
        }
    }

    private func sendDatagramToMac(_ datagram: WireGuardDatagram) {
        counters.wireGuardDatagramsFromServer &+= 1
        guard let connection = currentMacConnection else {
            counters.droppedWireGuardDatagrams &+= 1
            logger.error(
                "relay datagram to mac dropped error=no-current-mac-endpoint recovery=drop-datagram"
            )
            return
        }
        let bytesOut = UInt64(datagram.data.count)
        connection.send(
            content: datagram.data,
            completion: .contentProcessed { [weak self] error in
                Task { @MainActor [weak self] in
                    if let error {
                        self?.lastError = error.localizedDescription
                        logger.error(
                            "relay datagram to mac failed error=\(error.localizedDescription, privacy: .public)"
                        )
                        return
                    }
                    self?.counters.relayBytesOut &+= bytesOut
                    self?.counters.wireGuardDatagramsToMac &+= 1
                }
            }
        )
    }

    private func handle(listenerState state: NWListener.State) {
        switch state {
        case .ready:
            isAdvertising = true
            listenerPort = listener?.port?.rawValue
            logger.notice(
                "phone relay listener ready port=\(self.listenerPort ?? 0, privacy: .public)")
        case .failed(let error):
            lastError = error.localizedDescription
            isAdvertising = false
            listenerPort = nil
            logger.error(
                "phone relay listener state failed error=\(error.localizedDescription, privacy: .public)"
            )
        case .cancelled:
            isAdvertising = false
            listenerPort = nil
            logger.notice("phone relay listener cancelled")
        default:
            logger.debug("phone relay listener state changed")
        }
    }
}

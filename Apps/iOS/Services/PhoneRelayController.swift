import CellTunnelCore
import CellTunnelLog
import Foundation
import Network
import Observation
import UIKit

private let logger = CellTunnelLog.logger(category: .relay)
private let relayKeepAliveIdleSeconds = 10
private let relayKeepAliveIntervalSeconds = 5
private let relayKeepAliveProbeCount = 3
private let relayHeartbeatInterval: Duration = .seconds(8)

@MainActor
@Observable
final class PhoneRelayController: @unchecked Sendable {
    private let monitorQueue = DispatchQueue(label: "CellTunnelPhone.CellularMonitor")
    private var cellularMonitor: NWPathMonitor?
    private var listener: NWListener?
    var connections: [PhonePeerConnection] = []
    private let jsonEncoder = JSONEncoder()
    let wireGuardSession = WireGuardDatagramRelaySession()
    private var heartbeatTask: Task<Void, Never>?
    var throughputTask: Task<Void, Never>?
    var throughputBaseline = TunnelCounters()

    var isRunning = false
    var isAdvertising = false
    var connectedPeerName: String?
    var advertisedServiceName: String?
    var listenerPort: UInt16?
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
        startListener()
        startHeartbeatLoop()
        startThroughputLoop()
    }

    func stop() {
        let activeConnectionCount = connections.count
        logger.notice(
            "phone relay stopping activeConnections=\(activeConnectionCount, privacy: .public)")
        isRunning = false
        isAdvertising = false
        connectedPeerName = nil
        advertisedServiceName = nil
        listenerPort = nil
        UIApplication.shared.isIdleTimerDisabled = false
        stopHeartbeatLoop()
        stopThroughputLoop()
        wireGuardSession.stop()
        cellularMonitor?.cancel()
        cellularMonitor = nil
        listener?.cancel()
        listener = nil
        for connection in connections {
            connection.connection.cancel()
        }
        connections.removeAll()
    }

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()
        logger.notice("relay heartbeat loop starting interval=\(relayHeartbeatInterval, privacy: .public)")
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: relayHeartbeatInterval)
                } catch {
                    logger.notice(
                        "relay heartbeat loop sleep interrupted recovery=exit-loop error=\(error.localizedDescription, privacy: .public)"
                    )
                    return
                }
                guard !Task.isCancelled, let self else {
                    return
                }
                for peer in connections {
                    sendKeepAlive(to: peer)
                }
            }
        }
    }

    private func stopHeartbeatLoop() {
        logger.notice("relay heartbeat loop stopping")
        heartbeatTask?.cancel()
        heartbeatTask = nil
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
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = relayKeepAliveIdleSeconds
            tcpOptions.keepaliveInterval = relayKeepAliveIntervalSeconds
            tcpOptions.keepaliveCount = relayKeepAliveProbeCount
            let parameters = NWParameters(tls: nil, tcp: tcpOptions)
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters, on: resolvedRelayListenerPort())
            let serviceName = UIDevice.current.name
            advertisedServiceName = serviceName
            listener.service = NWListener.Service(name: serviceName, type: "_cellrelay._tcp")
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
                phone relay listener started service=_cellrelay._tcp \
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
        let peerConnection = PhonePeerConnection(connection: connection)
        replacePeerConnections(with: peerConnection)
        connectedPeerName = "Mac"
        wireGuardSession.datagramHandler = { [weak self, weak peerConnection] datagram in
            Task { @MainActor [weak self, weak peerConnection] in
                guard let peerConnection else {
                    logger.error(
                        "wireguard datagram relay output dropped error=missing-peer recovery=drop-datagram"
                    )
                    return
                }
                self?.sendWireGuardDatagram(datagram, streamID: 0, to: peerConnection)
            }
        }
        wireGuardSession.errorHandler = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.sendRelayErrorToPeers(message)
            }
        }
        let activeConnectionCount = connections.count
        logger.notice(
            "accepted relay peer activeConnections=\(activeConnectionCount, privacy: .public)")
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .failed(let error) = state {
                Task { @MainActor [weak self, weak connection] in
                    guard let connection else {
                        return
                    }
                    self?.handlePeerFailure(error, connection: connection)
                }
            }

            if case .cancelled = state, let connection {
                Task { @MainActor [weak self] in
                    self?.removePeerConnection(connection)
                    logger.notice(
                        "relay peer cancelled activeConnections=\(self?.connections.count ?? 0, privacy: .public)"
                    )
                }
            }
        }
        connection.start(queue: monitorQueue)
        receive(on: peerConnection)
    }

    private func receive(on peerConnection: PhonePeerConnection) {
        logger.debug("relay receive scheduled")
        let completion = receiveCompletion(for: peerConnection)
        peerConnection.connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_536,
            completion: completion
        )
    }

    private func receiveCompletion(
        for peerConnection: PhonePeerConnection
    ) -> @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void {
        { [weak self, weak peerConnection] data, _, isComplete, error in
            if let error {
                Task { @MainActor [weak self, weak peerConnection] in
                    guard let peerConnection else {
                        return
                    }
                    self?.handlePeerFailure(error, connection: peerConnection.connection)
                }
                return
            }

            if let data, !data.isEmpty {
                Task { @MainActor [weak self, weak peerConnection] in
                    guard let peerConnection else {
                        return
                    }

                    self?.handle(data: data, from: peerConnection)
                }
            }

            guard !isComplete, let peerConnection else {
                logger.notice("relay receive completed")
                return
            }

            Task { @MainActor [weak self] in
                self?.receive(on: peerConnection)
            }
        }
    }

    private func handle(data: Data, from peerConnection: PhonePeerConnection) {
        counters.relayBytesIn += UInt64(data.count)

        do {
            let frames = try peerConnection.frameBuffer.append(data)
            for frame in frames {
                handle(frame: frame, from: peerConnection)
            }
        } catch {
            lastError = "Protocol error: \(error)"
            logger.error(
                "relay protocol decode failed error=\(String(describing: error), privacy: .public)")
            peerConnection.connection.cancel()
        }
    }

    private func handle(frame: RelayFrame, from peerConnection: PhonePeerConnection) {
        peerConnection.lastAddressFamily = frame.addressFamily
        switch frame.operation {
        case .hello:
            connectedPeerName = "Mac"
            handleHello(frame: frame, from: peerConnection)
        case .wireGuardDatagram:
            handleWireGuardDatagram(frame: frame, from: peerConnection)
        case .keepAlive:
            logger.notice("relay keepalive received streamID=\(frame.streamID, privacy: .public)")
        case .error:
            lastError = String(data: frame.payload, encoding: .utf8) ?? "Peer reported an error"
            let reportedError = lastError ?? "unknown"
            logger.error("relay peer reported error=\(reportedError, privacy: .public)")
        default:
            break
        }
    }

    private func sendKeepAlive(to peerConnection: PhonePeerConnection) {
        let frame = RelayFrame(
            streamID: 0,
            operation: .keepAlive,
            addressFamily: peerConnection.lastAddressFamily,
            payload: Data()
        )
        logger.notice("sending relay keepalive")
        send(frame: frame, to: peerConnection)
    }

    private func handleHello(frame: RelayFrame, from peerConnection: PhonePeerConnection) {
        do {
            let handshake = try RelayHandshakePayload.decode(frame.payload)
            try wireGuardSession.start(endpoint: handshake.wireGuardServer)
            logger.notice(
                """
                relay handshake accepted streamID=\(frame.streamID, privacy: .public) \
                endpointFamily=\(handshake.wireGuardServer.addressFamily.rawValue, privacy: .public)
                """
            )
            sendPathStatus(
                addressFamily: handshake.wireGuardServer.addressFamily,
                streamID: frame.streamID,
                to: peerConnection
            )
        } catch {
            counters.droppedWireGuardDatagrams += 1
            lastError = "Handshake rejected: \(error.localizedDescription)"
            logger.error(
                """
                relay handshake rejected streamID=\(frame.streamID, privacy: .public) \
                error=\(error.localizedDescription, privacy: .public) recovery=send-relay-error
                """
            )
            sendError(
                "handshake rejected: \(error.localizedDescription)",
                addressFamily: frame.addressFamily,
                streamID: frame.streamID,
                to: peerConnection
            )
        }
    }

    private func handleWireGuardDatagram(
        frame: RelayFrame, from peerConnection: PhonePeerConnection
    ) {
        do {
            let datagram = try WireGuardDatagram(frame: frame)
            counters.wireGuardDatagramsFromMac += 1
            try wireGuardSession.sendToServer(datagram)
            counters.wireGuardDatagramsToServer += 1
        } catch {
            counters.droppedWireGuardDatagrams += 1
            lastError = "WireGuard datagram rejected: \(error.localizedDescription)"
            logger.error(
                """
                wireguard datagram frame rejected streamID=\(frame.streamID, privacy: .public) \
                error=\(error.localizedDescription, privacy: .public) recovery=send-relay-error
                """
            )
            sendError(
                "wireguard datagram rejected: \(error.localizedDescription)",
                addressFamily: frame.addressFamily,
                streamID: frame.streamID,
                to: peerConnection
            )
        }
    }

    private func sendPathStatus(
        addressFamily: RelayAddressFamily,
        streamID: UInt64,
        to peerConnection: PhonePeerConnection
    ) {
        let payload: Data
        do {
            payload = try jsonEncoder.encode(cellularPath)
        } catch {
            payload = Data()
            logger.error(
                "failed to encode cellular path error=\(error.localizedDescription, privacy: .public)"
            )
        }
        let frame = RelayFrame(
            streamID: streamID,
            operation: .pathStatus,
            addressFamily: addressFamily,
            payload: payload
        )
        logger.info("sending cellular path status streamID=\(streamID, privacy: .public)")
        send(frame: frame, to: peerConnection)
    }

    private func sendWireGuardDatagram(
        _ datagram: WireGuardDatagram,
        streamID: UInt64,
        to peerConnection: PhonePeerConnection
    ) {
        let frame = datagram.relayFrame(streamID: streamID)
        counters.wireGuardDatagramsFromServer += 1
        counters.wireGuardDatagramsToMac += 1
        logger.debug(
            "sending wireguard datagram streamID=\(streamID, privacy: .public)"
        )
        send(frame: frame, to: peerConnection)
    }

    private func sendError(
        _ message: String,
        addressFamily: RelayAddressFamily,
        streamID: UInt64,
        to peerConnection: PhonePeerConnection
    ) {
        let frame = RelayFrame(
            streamID: streamID,
            operation: .error,
            addressFamily: addressFamily,
            payload: Data(message.utf8)
        )
        logger.notice("sending relay error streamID=\(streamID, privacy: .public)")
        send(frame: frame, to: peerConnection)
    }

    private func sendRelayErrorToPeers(_ message: String) {
        lastError = message
        logger.error("sending relay error to peers error=\(message, privacy: .public)")
        for peerConnection in connections {
            sendError(
                "cellular udp failed: \(message)",
                addressFamily: peerConnection.lastAddressFamily,
                streamID: 0,
                to: peerConnection
            )
        }
    }

    private func send(frame: RelayFrame, to peerConnection: PhonePeerConnection) {
        let encodedFrame = RelayCodec.encode(frame)
        peerConnection.connection.send(
            content: encodedFrame,
            completion: .contentProcessed { [weak self] error in
                Task { @MainActor [weak self] in
                    if let error {
                        self?.lastError = error.localizedDescription
                        logger.error(
                            "relay send failed error=\(error.localizedDescription, privacy: .public)"
                        )
                        return
                    }

                    self?.counters.relayBytesOut += UInt64(encodedFrame.count)
                }
            })
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

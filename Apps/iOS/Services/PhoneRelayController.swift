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
    private var listener: NWListener?
    private var connections: [PhonePeerConnection] = []
    private let jsonEncoder = JSONEncoder()

    var isRunning = false
    var isAdvertising = false
    var connectedPeerName: String?
    var cellularPath = CellularPathSnapshot()
    var counters = TunnelCounters()
    var lastError: String?

    var stateDescription: String {
        if let lastError {
            return "Error: \(lastError)"
        }
        return isRunning ? "Running" : "Stopped"
    }

    var serviceDescription: String {
        isAdvertising ? "_cellrelay._tcp" : "Inactive"
    }

    var cellularInterfaceDescription: String {
        guard let interfaceName = cellularPath.interfaceName else {
            return "Unknown"
        }

        if let interfaceIndex = cellularPath.interfaceIndex {
            return "\(interfaceName) (\(interfaceIndex))"
        }

        return interfaceName
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
        startListener()
    }

    func stop() {
        let activeConnectionCount = connections.count
        logger.notice("phone relay stopping activeConnections=\(activeConnectionCount, privacy: .public)")
        isRunning = false
        isAdvertising = false
        connectedPeerName = nil
        UIApplication.shared.isIdleTimerDisabled = false
        cellularMonitor?.cancel()
        cellularMonitor = nil
        listener?.cancel()
        listener = nil
        for connection in connections {
            connection.connection.cancel()
        }
        connections.removeAll()
    }

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
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(name: UIDevice.current.name, type: "_cellrelay._tcp")
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
            logger.notice("phone relay listener started service=_cellrelay._tcp")
        } catch {
            lastError = error.localizedDescription
            isAdvertising = false
            logger.error("phone relay listener failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func accept(_ connection: NWConnection) {
        let peerConnection = PhonePeerConnection(connection: connection)
        connections.append(peerConnection)
        connectedPeerName = "Mac"
        let activeConnectionCount = connections.count
        logger.notice("accepted relay peer activeConnections=\(activeConnectionCount, privacy: .public)")
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .failed(let error) = state {
                Task { @MainActor [weak self] in
                    self?.lastError = error.localizedDescription
                    logger.error("relay peer failed error=\(error.localizedDescription, privacy: .public)")
                }
            }

            if case .cancelled = state, let connection {
                Task { @MainActor [weak self] in
                    self?.connections.removeAll { $0.connection === connection }
                    self?.connectedPeerName = self?.connections.isEmpty == true ? nil : self?.connectedPeerName
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
                Task { @MainActor [weak self] in
                    self?.lastError = error.localizedDescription
                    logger.error("relay receive failed error=\(error.localizedDescription, privacy: .public)")
                }
                return
            }

            if let data, !data.isEmpty {
                logger.debug("relay received bytes=\(data.count, privacy: .public)")
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
        counters.bytesIn += UInt64(data.count)

        do {
            let frames = try peerConnection.frameBuffer.append(data)
            logger.debug("decoded relay frames count=\(frames.count, privacy: .public)")
            for frame in frames {
                handle(frame: frame, from: peerConnection)
            }
        } catch {
            lastError = "Protocol error: \(error)"
            logger.error("relay protocol decode failed error=\(String(describing: error), privacy: .public)")
            peerConnection.connection.cancel()
        }
    }

    private func handle(frame: RelayFrame, from peerConnection: PhonePeerConnection) {
        logger.debug(
            """
            handling relay frame operation=\(frame.operation.rawValue, privacy: .public) \
            streamID=\(frame.streamID, privacy: .public) bytes=\(frame.payload.count, privacy: .public)
            """
        )
        switch frame.operation {
        case .hello:
            connectedPeerName = "Mac"
            sendPathStatus(addressFamily: frame.addressFamily, streamID: frame.streamID, to: peerConnection)
        case .tcpOpen:
            counters.tcpFlows += 1
        case .udpOpen, .udpDatagram:
            counters.udpFlows += 1
        case .icmpEcho:
            counters.icmpFlows += 1
        case .error:
            lastError = String(data: frame.payload, encoding: .utf8) ?? "Peer reported an error"
            let reportedError = lastError ?? "unknown"
            logger.error("relay peer reported error=\(reportedError, privacy: .public)")
        default:
            break
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
            logger.error("failed to encode cellular path error=\(error.localizedDescription, privacy: .public)")
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

    private func send(frame: RelayFrame, to peerConnection: PhonePeerConnection) {
        let encodedFrame = RelayCodec.encode(frame)
        peerConnection.connection.send(
            content: encodedFrame,
            completion: .contentProcessed { [weak self] error in
                Task { @MainActor [weak self] in
                    if let error {
                        self?.lastError = error.localizedDescription
                        logger.error("relay send failed error=\(error.localizedDescription, privacy: .public)")
                        return
                    }

                    self?.counters.bytesOut += UInt64(encodedFrame.count)
                    logger.debug("relay sent bytes=\(encodedFrame.count, privacy: .public)")
                }
            })
    }

    private func handle(listenerState state: NWListener.State) {
        switch state {
        case .ready:
            isAdvertising = true
            logger.notice("phone relay listener ready")
        case .failed(let error):
            lastError = error.localizedDescription
            isAdvertising = false
            logger.error("phone relay listener state failed error=\(error.localizedDescription, privacy: .public)")
        case .cancelled:
            isAdvertising = false
            logger.notice("phone relay listener cancelled")
        default:
            logger.debug("phone relay listener state changed")
        }
    }
}

private final class PhonePeerConnection: @unchecked Sendable {
    let connection: NWConnection
    var frameBuffer = RelayFrameBuffer()

    init(connection: NWConnection) {
        self.connection = connection
    }
}

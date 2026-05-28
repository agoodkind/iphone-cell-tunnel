import CellTunnelCore
import CellTunnelLog
import Foundation
import Network
import UIKit

private let logger = CellTunnelLog.logger(category: .relay)
private let statusPushIntervalSeconds: UInt64 = 5

@MainActor
final class PhoneControlListener {
    typealias EndpointHandler = @MainActor (RelayEndpoint) -> Void
    typealias StatusProvider = @MainActor () -> RelayControlMessage.Status

    private let queue = DispatchQueue(label: "io.goodkind.celltunnel.controlListener")
    private var listener: NWListener?
    private var currentConnection: NWConnection?
    private var statusTask: Task<Void, Never>?

    var onSetServerEndpoint: EndpointHandler?
    var statusProvider: StatusProvider?
    private(set) var listenerPort: UInt16?
    private(set) var advertisedServiceName: String?
    private(set) var lastError: String?

    func start(preferredServiceName: String) {
        stop()
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        let framerOptions = RelayControlFramerSupport.framerOptions()
        parameters.defaultProtocolStack.applicationProtocols.insert(framerOptions, at: 0)

        let nwListener: NWListener
        do {
            if let bindPort = NWEndpoint.Port(rawValue: relayControlListenerDefaultPort) {
                nwListener = try NWListener(using: parameters, on: bindPort)
            } else {
                nwListener = try NWListener(using: parameters)
            }
        } catch {
            lastError = error.localizedDescription
            logger.error(
                "control listener create failed error=\(error.localizedDescription, privacy: .public)"
            )
            return
        }

        nwListener.service = NWListener.Service(
            name: preferredServiceName,
            type: relayControlServiceType
        )
        advertisedServiceName = preferredServiceName

        nwListener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.accept(connection)
            }
        }
        nwListener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handle(listenerState: state)
            }
        }
        nwListener.start(queue: queue)
        listener = nwListener
        logger.notice(
            """
            control listener starting service=\(relayControlServiceType, privacy: .public) \
            name=\(preferredServiceName, privacy: .public) \
            port=\(relayControlListenerDefaultPort, privacy: .public)
            """
        )
        startStatusLoop()
    }

    func stop() {
        statusTask?.cancel()
        statusTask = nil
        currentConnection?.cancel()
        currentConnection = nil
        listener?.cancel()
        listener = nil
        listenerPort = nil
        advertisedServiceName = nil
        logger.notice("control listener stopped")
    }

    private func handle(listenerState state: NWListener.State) {
        switch state {
        case .ready:
            listenerPort = listener?.port?.rawValue
            logger.notice(
                "control listener ready port=\(self.listenerPort ?? 0, privacy: .public)"
            )
        case .failed(let error):
            lastError = error.localizedDescription
            logger.error(
                "control listener failed error=\(error.localizedDescription, privacy: .public)"
            )
        case .cancelled:
            listenerPort = nil
            logger.notice("control listener cancelled")
        default:
            logger.debug("control listener state changed")
        }
    }

    private func accept(_ connection: NWConnection) {
        logger.notice(
            """
            control listener accepting connection \
            endpoint=\(String(describing: connection.endpoint), privacy: .public)
            """
        )
        if let existing = currentConnection {
            logger.notice("control listener replacing previous control connection")
            existing.cancel()
        }
        currentConnection = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor [weak self, weak connection] in
                guard let connection else {
                    return
                }
                self?.handle(connectionState: state, connection: connection)
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func handle(connectionState state: NWConnection.State, connection: NWConnection) {
        switch state {
        case .failed(let error):
            logger.error(
                "control connection failed error=\(error.localizedDescription, privacy: .public)"
            )
            if currentConnection === connection {
                currentConnection = nil
            }
            connection.cancel()
        case .cancelled:
            if currentConnection === connection {
                currentConnection = nil
                logger.notice("control connection cancelled")
            }
        default:
            break
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, isComplete, error in
            if let error {
                logger.error(
                    "control connection receive failed error=\(error.localizedDescription, privacy: .public)"
                )
                Task { @MainActor [weak self, weak connection] in
                    guard let connection else { return }
                    if self?.currentConnection === connection {
                        self?.currentConnection = nil
                    }
                    connection.cancel()
                }
                return
            }

            if let data, !data.isEmpty {
                Task { @MainActor [weak self, weak connection] in
                    guard let connection else { return }
                    self?.handlePayload(data, connection: connection)
                }
            }

            guard !isComplete, let connection else {
                return
            }

            Task { @MainActor [weak self, weak connection] in
                guard let connection else { return }
                self?.receive(on: connection)
            }
        }
    }

    private func handlePayload(_ payload: Data, connection: NWConnection) {
        let decoded: RelayControlMessage
        do {
            decoded = try RelayControlMessageCodec.decode(payload)
        } catch let RelayControlCodecError.unsupportedVersion(version) {
            logger.error(
                "control message rejected unsupportedVersion=\(version, privacy: .public)"
            )
            let failure = RelayControlMessage.Failure(
                code: "unsupported-version",
                message: "iPhone supports control wire version \(relayControlWireVersion)"
            )
            send(.error(failure), on: connection)
            return
        } catch {
            logger.error(
                "control message decode failed error=\(error.localizedDescription, privacy: .public)"
            )
            let failure = RelayControlMessage.Failure(
                code: "decode-failure",
                message: error.localizedDescription
            )
            send(.error(failure), on: connection)
            return
        }

        switch decoded {
        case .setServerEndpoint(let payload):
            logger.notice(
                """
                control received set-server-endpoint host=\(payload.endpoint.host, privacy: .public) \
                port=\(payload.endpoint.port, privacy: .public) \
                family=\(payload.endpoint.addressFamily.rawValue, privacy: .public)
                """
            )
            onSetServerEndpoint?(payload.endpoint)
            let ack = RelayControlMessage.Acknowledge(
                requestKind: "set-server-endpoint",
                detail: "endpoint accepted"
            )
            send(.acknowledge(ack), on: connection)
            sendStatusSnapshot(on: connection)
        case .acknowledge:
            logger.debug("control received unexpected acknowledge from peer")
        case .status:
            logger.debug("control received unexpected status from peer")
        case .error(let payload):
            logger.error(
                "control received error from peer code=\(payload.code, privacy: .public) message=\(payload.message, privacy: .public)"
            )
        }
    }

    private func send(_ message: RelayControlMessage, on connection: NWConnection) {
        let payload: Data
        do {
            payload = try RelayControlMessageCodec.encode(message)
        } catch {
            logger.error(
                "control encode failed kind=\(message.kindLabel, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return
        }
        let framerMessage = NWProtocolFramer.Message(definition: RelayControlFramer.definition)
        let context = NWConnection.ContentContext(
            identifier: message.kindLabel,
            metadata: [framerMessage]
        )
        connection.send(
            content: payload,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { error in
                guard let error else { return }
                logger.error(
                    "control send failed kind=\(message.kindLabel, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        )
    }

    private func sendStatusSnapshot(on connection: NWConnection) {
        let status: RelayControlMessage.Status
        if let provider = statusProvider {
            status = provider()
        } else {
            status = RelayControlMessage.Status(hasCellularPath: false)
        }
        logger.debug(
            "control status push hasCellularPath=\(status.hasCellularPath, privacy: .public)"
        )
        send(.status(status), on: connection)
    }

    private func startStatusLoop() {
        statusTask?.cancel()
        logger.notice(
            "control status loop starting intervalSeconds=\(statusPushIntervalSeconds, privacy: .public)"
        )
        statusTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: statusPushIntervalSeconds * 1_000_000_000)
                } catch {
                    logger.notice(
                        "control status loop sleep interrupted recovery=exit-loop"
                    )
                    return
                }
                guard !Task.isCancelled else { return }
                guard let self, let connection = currentConnection else {
                    continue
                }
                sendStatusSnapshot(on: connection)
            }
        }
    }
}

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network

private let logger = CellTunnelLog.logger(category: .daemon)
private let handshakeTimeoutSeconds: UInt64 = 10

private let tcpKeepaliveIdleSeconds = 10
private let tcpKeepaliveIntervalSeconds = 5
private let tcpKeepaliveRetryCount = 3

enum ControlChannelError: LocalizedError {
    case acknowledgeMissing
    case alreadyStarted
    case connectionFailed(String)
    case discoveryTimeout
    case handshakeTimeout
    case remoteError(RemoteErrorPayload)

    struct RemoteErrorPayload: Sendable, Equatable {
        var code: String
        var message: String
    }

    var errorDescription: String? {
        switch self {
        case .acknowledgeMissing:
            return "control channel did not receive set-server-endpoint acknowledgement"
        case .alreadyStarted:
            return "control channel already started"
        case .connectionFailed(let detail):
            return "control channel connection failed: \(detail)"
        case .discoveryTimeout:
            return "control channel could not discover iPhone control listener"
        case .handshakeTimeout:
            return "control channel handshake timed out"
        case .remoteError(let payload):
            return "control channel remote error code=\(payload.code) message=\(payload.message)"
        }
    }
}

actor ControlChannel {
    private let serverEndpoint: RelayEndpoint
    private let connectionQueue = DispatchQueue(label: "io.goodkind.celltunnel.controlChannel")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var statusContinuation: AsyncStream<RelayControlMessage.Status>.Continuation?
    private var didStart = false

    let statusStream: AsyncStream<RelayControlMessage.Status>

    init(serverEndpoint: RelayEndpoint) {
        self.serverEndpoint = serverEndpoint
        var continuationCapture: AsyncStream<RelayControlMessage.Status>.Continuation?
        self.statusStream = AsyncStream { continuation in
            continuationCapture = continuation
        }
        self.statusContinuation = continuationCapture
    }

    func start() async throws {
        guard !didStart else {
            throw ControlChannelError.alreadyStarted
        }
        didStart = true

        let endpoint = try await discoverEndpoint()
        try await dialAndHandshake(to: endpoint)
    }

    func stop() {
        statusContinuation?.finish()
        statusContinuation = nil
        connection?.cancel()
        connection = nil
        browser?.cancel()
        browser = nil
        logger.notice("control channel stopped")
    }

    private func discoverEndpoint() async throws -> NWEndpoint {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(
            type: relayControlServiceType,
            domain: nil
        )
        let nwBrowser = NWBrowser(for: descriptor, using: parameters)
        self.browser = nwBrowser

        let endpointHolder = BrowsedEndpointHolder()

        return try await awaitDiscoveredEndpoint(
            browser: nwBrowser,
            endpointHolder: endpointHolder
        )
    }

    private func awaitDiscoveredEndpoint(
        browser nwBrowser: NWBrowser,
        endpointHolder: BrowsedEndpointHolder
    ) async throws -> NWEndpoint {
        try await withCheckedThrowingContinuation { continuation in
            nwBrowser.stateUpdateHandler = { state in
                logger.notice(
                    "control discovery browser state=\(String(describing: state), privacy: .public)"
                )
            }
            nwBrowser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    if case .service = result.endpoint {
                        if endpointHolder.deliverIfNeeded(
                            result.endpoint, continuation: continuation
                        ) {
                            return
                        }
                    }
                }
            }
            nwBrowser.start(queue: connectionQueue)

            scheduleDiscoveryTimeout(holder: endpointHolder, continuation: continuation)
        }
    }

    private func scheduleDiscoveryTimeout(
        holder: BrowsedEndpointHolder,
        continuation: CheckedContinuation<NWEndpoint, Error>
    ) {
        connectionQueue.asyncAfter(
            deadline: .now() + .seconds(Int(handshakeTimeoutSeconds))
        ) { [weak self] in
            guard let self else {
                return
            }
            if holder.deliverTimeout(continuation: continuation) {
                Task { await self.cancelBrowser() }
            }
        }
    }

    private func cancelBrowser() {
        logger.notice("control channel browser cancel requested")
        browser?.cancel()
        browser = nil
    }

    private func dialAndHandshake(to endpoint: NWEndpoint) async throws {
        let parameters = NWParameters(tls: nil, tcp: tcpOptions())
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        parameters.defaultProtocolStack.applicationProtocols.insert(
            RelayControlFramerSupport.framerOptions(),
            at: 0
        )

        let nwConnection = NWConnection(to: endpoint, using: parameters)
        connection = nwConnection

        let _: Void = try await withCheckedThrowingContinuation { continuation in
            let resolver = ConnectionReadyResolver()
            nwConnection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resolver.resolveOnce(with: .success(())) {
                        logger.notice("control channel connection ready")
                    }
                case .failed(let error):
                    if resolver.resolveOnce(
                        with: .failure(
                            ControlChannelError.connectionFailed(error.localizedDescription)
                        )
                    ) {
                        logger.error(
                            "control channel failed error=\(error.localizedDescription, privacy: .public)"
                        )
                    }
                case .cancelled:
                    _ = resolver.resolveOnce(
                        with: .failure(
                            ControlChannelError.connectionFailed("connection cancelled")
                        )
                    )
                default:
                    break
                }
            }
            resolver.bind(continuation: continuation)
            nwConnection.start(queue: connectionQueue)

            connectionQueue.asyncAfter(
                deadline: .now() + .seconds(Int(handshakeTimeoutSeconds))
            ) {
                _ = resolver.resolveOnce(with: .failure(ControlChannelError.handshakeTimeout))
            }
        }

        try await sendSetServerEndpoint(on: nwConnection)
        startReceiveLoop(on: nwConnection)
    }

    private func tcpOptions() -> NWProtocolTCP.Options {
        let options = NWProtocolTCP.Options()
        options.enableKeepalive = true
        options.keepaliveIdle = tcpKeepaliveIdleSeconds
        options.keepaliveInterval = tcpKeepaliveIntervalSeconds
        options.keepaliveCount = tcpKeepaliveRetryCount
        options.noDelay = true
        return options
    }

    private func sendSetServerEndpoint(on connection: NWConnection) async throws {
        logger.notice(
            "control channel sending set-server-endpoint host=\(self.serverEndpoint.host, privacy: .public) port=\(self.serverEndpoint.port, privacy: .public)"
        )
        let message = RelayControlMessage.setServerEndpoint(
            RelayControlMessage.SetServerEndpoint(endpoint: serverEndpoint)
        )
        try await send(message, on: connection)
        try await awaitAcknowledge(on: connection, requestKind: "set-server-endpoint")
    }

    private func send(
        _ message: RelayControlMessage,
        on connection: NWConnection
    ) async throws {
        let payload = try RelayControlMessageCodec.encode(message)
        let framerMessage = NWProtocolFramer.Message(definition: RelayControlFramer.definition)
        let context = NWConnection.ContentContext(
            identifier: message.kindLabel,
            metadata: [framerMessage]
        )
        let _: Void = try await withCheckedThrowingContinuation { continuation in
            connection.send(
                content: payload,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume()
                }
            )
        }
        logger.notice(
            "control channel sent kind=\(message.kindLabel, privacy: .public) bytes=\(payload.count, privacy: .public)"
        )
    }

    private func awaitAcknowledge(
        on connection: NWConnection,
        requestKind: String
    ) async throws {
        let received = try await receiveOne(on: connection)
        switch received {
        case .acknowledge(let payload) where payload.requestKind == requestKind:
            logger.notice(
                "control channel acknowledge received requestKind=\(payload.requestKind, privacy: .public)"
            )
        case .error(let failure):
            throw ControlChannelError.remoteError(
                ControlChannelError.RemoteErrorPayload(
                    code: failure.code,
                    message: failure.message
                )
            )
        case .status(let snapshot):
            logger.notice(
                "control channel received status before ack hasCellularPath=\(snapshot.hasCellularPath, privacy: .public)"
            )
            statusContinuation?.yield(snapshot)
            try await awaitAcknowledge(on: connection, requestKind: requestKind)
        default:
            throw ControlChannelError.acknowledgeMissing
        }
    }

    private func receiveOne(on connection: NWConnection) async throws -> RelayControlMessage {
        try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, !data.isEmpty else {
                    continuation.resume(
                        throwing: ControlChannelError.connectionFailed("empty payload received")
                    )
                    return
                }
                do {
                    let decoded = try RelayControlMessageCodec.decode(data)
                    continuation.resume(returning: decoded)
                } catch {
                    logger.error(
                        """
                        control channel decode failed during receive \
                        error=\(error.localizedDescription, privacy: .public)
                        """
                    )
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func startReceiveLoop(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if let error {
                logger.error(
                    "control channel receive failed error=\(error.localizedDescription, privacy: .public)"
                )
                return
            }
            if let data, !data.isEmpty {
                Task { [weak self] in
                    await self?.handleStreamPayload(data)
                }
            }
            Task { [weak self] in
                await self?.continueReceiveLoop(on: connection)
            }
        }
    }

    private func continueReceiveLoop(on connection: NWConnection) {
        startReceiveLoop(on: connection)
    }

    private func handleStreamPayload(_ data: Data) {
        let message: RelayControlMessage
        do {
            message = try RelayControlMessageCodec.decode(data)
        } catch {
            logger.error(
                "control channel decode failed error=\(error.localizedDescription, privacy: .public)"
            )
            return
        }
        switch message {
        case .status(let snapshot):
            logger.notice(
                """
                control channel status hasCellularPath=\(snapshot.hasCellularPath, privacy: .public) \
                interface=\(snapshot.cellularInterface ?? "none", privacy: .public)
                """
            )
            statusContinuation?.yield(snapshot)
        case .error(let failure):
            logger.error(
                "control channel error from peer code=\(failure.code, privacy: .public) message=\(failure.message, privacy: .public)"
            )
        case .acknowledge(let payload):
            logger.debug(
                "control channel late ack requestKind=\(payload.requestKind, privacy: .public)"
            )
        case .setServerEndpoint:
            logger.debug("control channel received unexpected set-server-endpoint from peer")
        }
    }
}

private final class BrowsedEndpointHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false

    func deliverIfNeeded(
        _ endpoint: NWEndpoint,
        continuation: CheckedContinuation<NWEndpoint, Error>
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resolved {
            return false
        }
        resolved = true
        continuation.resume(returning: endpoint)
        return true
    }

    func deliverTimeout(continuation: CheckedContinuation<NWEndpoint, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resolved {
            return false
        }
        resolved = true
        continuation.resume(throwing: ControlChannelError.discoveryTimeout)
        return true
    }
}

private final class ConnectionReadyResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    func bind(continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    func resolveOnce(with result: Result<Void, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let captured = continuation else {
            return false
        }
        continuation = nil
        switch result {
        case .success:
            captured.resume()
        case .failure(let error):
            captured.resume(throwing: error)
        }
        return true
    }
}

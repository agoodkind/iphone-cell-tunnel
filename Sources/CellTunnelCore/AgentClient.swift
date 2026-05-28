import CellTunnelLog
import Foundation

#if os(macOS)
    private let logger = CellTunnelLog.logger(category: .daemon)

    private let agentSpawnPollSeconds: Double = 0.1
    private let agentSpawnTimeoutSeconds: Double = 10

    public actor AgentClient: TunnelControlClientProtocol {
        private let endpointPath: String
        private let binaryName: String
        private var connection: NSXPCConnection?

        public init(
            endpointPath: String = agentControlEndpointPath,
            binaryName: String = agentBinaryName
        ) {
            self.endpointPath = endpointPath
            self.binaryName = binaryName
        }

        public func shutdown() {
            logger.notice("agent client shutdown requested")
            tearDownConnection(reason: "shutdown")
        }

        public func status() async throws -> TunnelDaemonStatusSnapshot {
            logger.notice("agent client invoked rpc=status")
            let response = try await send(request: .status, operationName: "status")
            return try requireStatus(from: response, operationName: "status")
        }

        public func check() async throws -> TunnelEnvironmentReport {
            logger.notice("agent client invoked rpc=check")
            let response = try await send(request: .check, operationName: "check")
            if let failure = response.failure {
                throw mapFailure(failure)
            }
            guard let report = response.report else {
                throw TunnelDaemonError.transportFailure("missing check response payload")
            }
            return report
        }

        public func startTunnel(
            settings: TunnelStartSettings
        ) async throws -> TunnelDaemonStatusSnapshot {
            logger.notice("agent client invoked rpc=start-tunnel")
            let response = try await send(
                request: .startTunnel(settings),
                operationName: "startTunnel"
            )
            return try requireStatus(from: response, operationName: "startTunnel")
        }

        public func stopTunnel() async throws -> TunnelDaemonStatusSnapshot {
            logger.notice("agent client invoked rpc=stop-tunnel")
            let response = try await send(request: .stopTunnel, operationName: "stopTunnel")
            return try requireStatus(from: response, operationName: "stopTunnel")
        }

        public func startRelayDiscovery() async throws -> TunnelDiscoverySnapshot {
            logger.notice("agent client invoked rpc=start-relay-discovery")
            let response = try await send(
                request: .startRelayDiscovery,
                operationName: "startRelayDiscovery"
            )
            return try requireDiscovery(from: response, operationName: "startRelayDiscovery")
        }

        public func stopRelayDiscovery() async throws -> TunnelDiscoverySnapshot {
            logger.notice("agent client invoked rpc=stop-relay-discovery")
            let response = try await send(
                request: .stopRelayDiscovery,
                operationName: "stopRelayDiscovery"
            )
            return try requireDiscovery(from: response, operationName: "stopRelayDiscovery")
        }

        public func listRelayServices() async throws -> TunnelDiscoverySnapshot {
            logger.notice("agent client invoked rpc=list-relay-services")
            let response = try await send(
                request: .listRelayServices,
                operationName: "listRelayServices"
            )
            return try requireDiscovery(from: response, operationName: "listRelayServices")
        }

        public func selectRelayService(serviceID: String) async throws -> TunnelDiscoverySnapshot {
            logger.notice(
                "agent client invoked rpc=select-relay-service serviceID=\(serviceID, privacy: .public)"
            )
            let response = try await send(
                request: .selectRelayService(serviceID: serviceID),
                operationName: "selectRelayService"
            )
            return try requireDiscovery(from: response, operationName: "selectRelayService")
        }
    }

    extension AgentClient {
        private func send(
            request: AgentControlRequest,
            operationName: String
        ) async throws -> AgentControlResponse {
            let payload = try encode(request: request, operationName: operationName)
            let proxy = try await activeProxy()
            let responseData = try await transmit(
                payload: payload,
                proxy: proxy,
                operationName: operationName
            )
            let response = try decode(responseData: responseData, operationName: operationName)
            try validate(responseVersion: response.version, operationName: operationName)
            logger.notice(
                "\(operationName) agent rpc completed responseVersion=\(response.version, privacy: .public)"
            )
            return response
        }

        private func encode(request: AgentControlRequest, operationName: String) throws -> Data {
            do {
                return try JSONEncoder().encode(AgentControlEnvelope(request: request))
            } catch {
                logger.error(
                    """
                    \(operationName) agent request encode failed \
                    details=\(String(describing: error), privacy: .public) \
                    recovery=throw-transport-failure
                    """
                )
                throw TunnelDaemonError.transportFailure(
                    "encode \(operationName) request failed: \(error.localizedDescription)"
                )
            }
        }

        private func decode(
            responseData: Data,
            operationName: String
        ) throws -> AgentControlResponse {
            do {
                return try JSONDecoder().decode(AgentControlResponse.self, from: responseData)
            } catch {
                logger.error(
                    """
                    \(operationName) agent response decode failed \
                    details=\(String(describing: error), privacy: .public) \
                    recovery=throw-transport-failure
                    """
                )
                throw TunnelDaemonError.transportFailure(
                    "decode \(operationName) response failed: \(error.localizedDescription)"
                )
            }
        }

        private func transmit(
            payload: Data,
            proxy: any AgentControlXPC,
            operationName: String
        ) async throws -> Data {
            logger.notice(
                "\(operationName) agent rpc transmitting bytes=\(payload.count, privacy: .public)"
            )
            return try await withCheckedThrowingContinuation { continuation in
                proxy.sendRequest(payload) { reply in
                    guard let reply else {
                        continuation.resume(
                            throwing: TunnelDaemonError.transportFailure(
                                "agent returned no payload for \(operationName)"
                            )
                        )
                        return
                    }
                    continuation.resume(returning: reply)
                }
            }
        }

        private func activeProxy() async throws -> any AgentControlXPC {
            let connection = try await activeConnection()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                logger.error(
                    "agent xpc proxy error details=\(String(describing: error), privacy: .public)"
                )
            }
            guard let typed = proxy as? any AgentControlXPC else {
                tearDownConnection(reason: "proxy-cast-failed")
                throw TunnelDaemonError.transportFailure(
                    "agent proxy does not conform to control protocol"
                )
            }
            return typed
        }

        private func activeConnection() async throws -> NSXPCConnection {
            if let connection {
                return connection
            }
            let endpoint = try await resolveEndpoint()
            let created = NSXPCConnection(listenerEndpoint: endpoint)
            created.remoteObjectInterface = NSXPCInterface(with: AgentControlXPC.self)
            created.invalidationHandler = { [weak self] in
                Task { await self?.handleInvalidation() }
            }
            created.interruptionHandler = {
                logger.notice("agent xpc connection interrupted")
            }
            created.resume()
            connection = created
            logger.notice("agent xpc connection opened")
            return created
        }

        private func resolveEndpoint() async throws -> NSXPCListenerEndpoint {
            if let endpoint = readEndpoint(operationName: "resolve-existing") {
                return endpoint
            }
            try spawnAgent()
            let appeared = await AgentEndpointWaiter.wait(
                forFileAt: endpointPath,
                pollSeconds: agentSpawnPollSeconds,
                timeoutSeconds: agentSpawnTimeoutSeconds
            )
            guard appeared else {
                logger.error(
                    """
                    agent endpoint did not appear path=\(self.endpointPath, privacy: .public) \
                    recovery=throw-daemon-unavailable
                    """
                )
                throw TunnelDaemonError.daemonUnavailable(endpointPath)
            }
            guard let endpoint = readEndpoint(operationName: "resolve-after-spawn") else {
                throw TunnelDaemonError.transportFailure("agent endpoint file is unreadable")
            }
            return endpoint
        }

        private func readEndpoint(operationName: String) -> NSXPCListenerEndpoint? {
            let url = URL(fileURLWithPath: endpointPath)
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                logger.notice(
                    "\(operationName) agent endpoint file absent path=\(self.endpointPath, privacy: .public)"
                )
                return nil
            }
            do {
                return try NSKeyedUnarchiver.unarchivedObject(
                    ofClass: NSXPCListenerEndpoint.self,
                    from: data
                )
            } catch {
                logger.error(
                    """
                    \(operationName) agent endpoint decode failed \
                    details=\(String(describing: error), privacy: .public) \
                    recovery=return-nil
                    """
                )
                return nil
            }
        }

        private func spawnAgent() throws {
            let executableURL = try resolveAgentBinaryURL()
            let process = Process()
            process.executableURL = executableURL
            process.arguments = []
            do {
                try process.run()
            } catch {
                logger.error(
                    """
                    agent spawn failed path=\(executableURL.path, privacy: .public) \
                    details=\(String(describing: error), privacy: .public) \
                    recovery=throw-transport-failure
                    """
                )
                throw TunnelDaemonError.transportFailure(
                    "failed to spawn agent at \(executableURL.path): \(error.localizedDescription)"
                )
            }
            logger.notice("agent spawned path=\(executableURL.path, privacy: .public)")
        }

        private func resolveAgentBinaryURL() throws -> URL {
            let environment = ProcessInfo.processInfo.environment
            let override = environment[agentBinaryEnvironmentVariable]?
                .trimmingCharacters(in: .whitespaces)
            if let override, !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            let executablePath = CommandLine.arguments.first ?? binaryName
            let sibling = URL(fileURLWithPath: executablePath)
                .deletingLastPathComponent()
                .appendingPathComponent(binaryName)
            if FileManager.default.isExecutableFile(atPath: sibling.path) {
                return sibling
            }
            logger.error(
                """
                agent binary not found beside CLI path=\(sibling.path, privacy: .public) \
                recovery=throw-transport-failure
                """
            )
            throw TunnelDaemonError.transportFailure(
                "agent binary not found beside CLI and \(agentBinaryEnvironmentVariable) is unset"
            )
        }

        private func handleInvalidation() {
            connection = nil
            logger.notice("agent xpc connection invalidated")
        }

        private func tearDownConnection(reason: String) {
            guard let active = connection else {
                return
            }
            active.invalidate()
            connection = nil
            logger.notice("agent xpc connection torn down reason=\(reason, privacy: .public)")
        }

        private func validate(responseVersion: Int, operationName: String) throws {
            if responseVersion > agentControlWireVersion {
                logger.error(
                    """
                    \(operationName) agent response rejected \
                    receivedVersion=\(responseVersion, privacy: .public) \
                    supportedVersion=\(agentControlWireVersion, privacy: .public)
                    """
                )
                throw TunnelDaemonError.transportFailure(
                    "unsupported agent response version \(responseVersion)"
                )
            }
        }

        private func requireStatus(
            from response: AgentControlResponse,
            operationName: String
        ) throws -> TunnelDaemonStatusSnapshot {
            if let failure = response.failure {
                throw mapFailure(failure)
            }
            guard let status = response.status else {
                throw TunnelDaemonError.transportFailure("missing \(operationName) status payload")
            }
            return status
        }

        private func requireDiscovery(
            from response: AgentControlResponse,
            operationName: String
        ) throws -> TunnelDiscoverySnapshot {
            if let failure = response.failure {
                throw mapFailure(failure)
            }
            guard let discovery = response.discovery else {
                throw TunnelDaemonError.transportFailure(
                    "missing \(operationName) discovery payload"
                )
            }
            return discovery
        }

        private func mapFailure(_ failure: AgentControlFailure) -> TunnelDaemonError {
            TunnelDaemonError.controlFailure(
                TunnelControlFailure(errorCode: failure.errorCode, message: failure.message)
            )
        }
    }

    private enum AgentEndpointWaiter {
        static func wait(
            forFileAt path: String,
            pollSeconds: Double,
            timeoutSeconds: Double
        ) async -> Bool {
            logger.notice("agent endpoint wait starting path=\(path, privacy: .public)")
            return await withCheckedContinuation { continuation in
                let box = AgentEndpointWaitBox(continuation: continuation)
                let queue = DispatchQueue(label: "io.goodkind.celltunnel.agent.endpoint-wait")
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: pollSeconds)
                let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
                timer.setEventHandler {
                    if FileManager.default.fileExists(atPath: path) {
                        box.finish(timer: timer, value: true)
                        return
                    }
                    if ContinuousClock.now >= deadline {
                        box.finish(timer: timer, value: false)
                    }
                }
                timer.resume()
            }
        }
    }

    private final class AgentEndpointWaitBox: @unchecked Sendable {
        private let continuation: CheckedContinuation<Bool, Never>
        private let lock = NSLock()
        private var finished = false

        init(continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func finish(timer: DispatchSourceTimer, value: Bool) {
            lock.lock()
            if finished {
                lock.unlock()
                return
            }
            finished = true
            lock.unlock()
            timer.cancel()
            logger.notice("agent endpoint wait finished appeared=\(value, privacy: .public)")
            continuation.resume(returning: value)
        }
    }
#endif

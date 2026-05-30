import CellTunnelLog
import Foundation

#if os(macOS)
    private let logger = CellTunnelLog.logger(category: .daemon)

    public actor AgentClient: TunnelControlClientProtocol {
        private var connection: NSXPCConnection?

        public init(
            endpointPath: String = "",
            binaryName: String = agentBinaryName,
            environment: [String: String] = [:]
        ) {
            _ = endpointPath
            _ = binaryName
            _ = environment
        }

        public func shutdown() {
            logger.notice("agent client shutdown requested")
            tearDownConnection(reason: "shutdown")
        }

        public func resetConfiguration() async throws {
            logger.notice("agent client invoked rpc=reset")
            let response = try await send(request: .reset, operationName: "reset")
            if let failure = response.failure {
                throw mapFailure(failure)
            }
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
            let proxy = try activeProxy()
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

        private func activeProxy() throws -> any AgentControlXPC {
            let connection = activeConnection()
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

        private func activeConnection() -> NSXPCConnection {
            if let connection {
                return connection
            }
            let created = NSXPCConnection(machServiceName: agentMachServiceName)
            created.remoteObjectInterface = NSXPCInterface(with: AgentControlXPC.self)
            created.invalidationHandler = { [weak self] in
                Task { await self?.handleInvalidation() }
            }
            created.interruptionHandler = {
                logger.notice("agent xpc connection interrupted")
            }
            created.resume()
            connection = created
            logger.notice(
                "agent xpc connection opened machServiceName=\(agentMachServiceName, privacy: .public)"
            )
            return created
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
#endif

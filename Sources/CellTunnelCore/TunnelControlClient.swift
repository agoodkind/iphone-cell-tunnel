import CellTunnelLog
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

private let logger = CellTunnelLog.logger(category: .daemon)

private let tunnelControlAuthority = "localhost"
private let initialRPCRetryDelay = Duration.milliseconds(250)
private let initialRPCAttemptCount = 2

private typealias RuntimeTransport = HTTP2ClientTransport.Posix
private typealias RuntimeClient = GRPCClient<RuntimeTransport>
private typealias GeneratedTunnelControlStub = CTControlV1_TunnelControlService.Client<
    RuntimeTransport
>

public let defaultTunnelControlSocketPath = "/var/run/io.goodkind.celltunnel/control.sock"

public protocol TunnelControlClientProtocol: Sendable {
    func status() async throws -> TunnelDaemonStatusSnapshot
    func check() async throws -> TunnelEnvironmentReport
    func startTunnel(settings: TunnelStartSettings) async throws -> TunnelDaemonStatusSnapshot
    func stopTunnel() async throws -> TunnelDaemonStatusSnapshot
    func startRelayDiscovery() async throws -> TunnelDiscoverySnapshot
    func stopRelayDiscovery() async throws -> TunnelDiscoverySnapshot
    func listRelayServices() async throws -> TunnelDiscoverySnapshot
    func selectRelayService(serviceID: String) async throws -> TunnelDiscoverySnapshot
}

public actor TunnelControlClient: TunnelControlClientProtocol {
    private let socketPath: String
    private var activeClientID: UUID?
    private var client: RuntimeClient?
    private var runnerTask: Task<Void, Never>?
    private var shouldRetryInitialRPC = false

    public init(socketPath: String = defaultTunnelControlSocketPath) {
        self.socketPath = socketPath
    }

    public func shutdown() {
        logger.notice(
            "tunnel control client shutdown requested socket=\(self.socketPath, privacy: .public)")
        teardownClientRuntime(reason: "shutdown")
    }

    public func status() async throws -> TunnelDaemonStatusSnapshot {
        logger.notice("requesting tunnel daemon status socket=\(self.socketPath, privacy: .public)")
        let response = try await performRPC(operationName: "status") { stub in
            try await stub.status(CTControlV1_StatusRequest())
        }
        switch response.result {
        case .status(let status):
            return TunnelDaemonStatusSnapshot(proto: status)
        case .error(let error):
            throw TunnelDaemonError(proto: error)
        case .none:
            throw TunnelDaemonError.transportFailure("missing status response payload")
        }
    }

    public func check() async throws -> TunnelEnvironmentReport {
        logger.notice(
            "requesting tunnel daemon environment check socket=\(self.socketPath, privacy: .public)"
        )
        let response = try await performRPC(operationName: "check") { stub in
            try await stub.check(CTControlV1_CheckRequest())
        }
        switch response.result {
        case .report(let report):
            return TunnelEnvironmentReport(proto: report)
        case .error(let error):
            throw TunnelDaemonError(proto: error)
        case .none:
            throw TunnelDaemonError.transportFailure("missing check response payload")
        }
    }

    public func startTunnel(
        settings: TunnelStartSettings
    ) async throws -> TunnelDaemonStatusSnapshot {
        logger.notice(
            """
            requesting tunnel daemon start socket=\(self.socketPath, privacy: .public) \
            relayOverrideConfigured=\(settings.hasLocalRelayEndpoint, privacy: .public)
            """
        )
        var request = CTControlV1_StartTunnelRequest()
        request.settings.wireGuardConfigPath = settings.wireGuardConfigPath
        if let relayEndpoint = settings.relayEndpoint {
            request.settings.relayEndpoint = relayEndpoint.proto
        }
        let immutableRequest = request
        let response = try await performRPC(operationName: "startTunnel") { stub in
            try await stub.startTunnel(immutableRequest)
        }
        switch response.result {
        case .status(let status):
            return TunnelDaemonStatusSnapshot(proto: status)
        case .error(let error):
            throw TunnelDaemonError(proto: error)
        case .none:
            throw TunnelDaemonError.transportFailure("missing start response payload")
        }
    }

    public func stopTunnel() async throws -> TunnelDaemonStatusSnapshot {
        logger.notice("requesting tunnel daemon stop socket=\(self.socketPath, privacy: .public)")
        let response = try await performRPC(operationName: "stopTunnel") { stub in
            try await stub.stopTunnel(CTControlV1_StopTunnelRequest())
        }
        switch response.result {
        case .status(let status):
            return TunnelDaemonStatusSnapshot(proto: status)
        case .error(let error):
            throw TunnelDaemonError(proto: error)
        case .none:
            throw TunnelDaemonError.transportFailure("missing stop response payload")
        }
    }

    public func startRelayDiscovery() async throws -> TunnelDiscoverySnapshot {
        logger.notice(
            "requesting relay discovery start socket=\(self.socketPath, privacy: .public)")
        let response = try await performRPC(operationName: "startRelayDiscovery") { stub in
            try await stub.startRelayDiscovery(CTControlV1_StartRelayDiscoveryRequest())
        }
        return try decodeDiscovery(
            response.result, missingPayloadMessage: "missing discovery start payload")
    }

    public func stopRelayDiscovery() async throws -> TunnelDiscoverySnapshot {
        logger.notice("requesting relay discovery stop socket=\(self.socketPath, privacy: .public)")
        let response = try await performRPC(operationName: "stopRelayDiscovery") { stub in
            try await stub.stopRelayDiscovery(CTControlV1_StopRelayDiscoveryRequest())
        }
        return try decodeDiscovery(
            response.result, missingPayloadMessage: "missing discovery stop payload")
    }

    public func listRelayServices() async throws -> TunnelDiscoverySnapshot {
        logger.notice("requesting relay discovery list socket=\(self.socketPath, privacy: .public)")
        let response = try await performRPC(operationName: "listRelayServices") { stub in
            try await stub.listRelayServices(CTControlV1_ListRelayServicesRequest())
        }
        return try decodeDiscovery(
            response.result, missingPayloadMessage: "missing discovery list payload")
    }

    public func selectRelayService(serviceID: String) async throws -> TunnelDiscoverySnapshot {
        logger.notice(
            "requesting relay service selection socket=\(self.socketPath, privacy: .public)")
        var request = CTControlV1_SelectRelayServiceRequest()
        request.serviceID = serviceID
        let immutableRequest = request
        let response = try await performRPC(operationName: "selectRelayService") { stub in
            try await stub.selectRelayService(immutableRequest)
        }
        return try decodeDiscovery(
            response.result, missingPayloadMessage: "missing relay selection payload")
    }
}

extension TunnelControlClient {
    private func performRPC<Result: Sendable>(
        operationName: String,
        _ operation: @Sendable (GeneratedTunnelControlStub) async throws -> Result
    ) async throws -> Result {
        var attempt = 1

        while true {
            let stub = try makeStub()
            do {
                let result = try await operation(stub)
                shouldRetryInitialRPC = false
                logger.notice(
                    "\(operationName) rpc completed attempt=\(attempt, privacy: .public) socket=\(self.socketPath, privacy: .public)"
                )
                return result
            } catch {
                let renderedError = renderTransportError(error)
                let shouldRetryInitialRequest = shouldRetryInitialRPC
                let shouldRetry =
                    shouldRetryInitialRequest
                    && attempt < initialRPCAttemptCount
                    && shouldRetryInitialRPCFailure(error)
                shouldRetryInitialRPC = false
                logger.error(
                    """
                    \(operationName) rpc failed attempt=\(attempt, privacy: .public) \
                    socket=\(self.socketPath, privacy: .public) details=\(renderedError, privacy: .public)
                    """
                )
                if shouldRetry {
                    teardownClientRuntime(reason: "\(operationName)-initial-rpc-retry")
                    try await Task.sleep(for: initialRPCRetryDelay)
                    attempt += 1
                    continue
                }
                throw mapClientError(error)
            }
        }
    }

    private func makeStub() throws -> GeneratedTunnelControlStub {
        let client = try activeClient()
        return GeneratedTunnelControlStub(wrapping: client)
    }

    private func activeClient() throws -> RuntimeClient {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw TunnelDaemonError.daemonUnavailable(socketPath)
        }

        if let client {
            return client
        }

        let clientID = UUID()
        let transport = try buildTransport()
        let client = RuntimeClient(transport: transport)
        shouldRetryInitialRPC = true
        activeClientID = clientID
        self.client = client
        runnerTask = Task {
            do {
                try await client.runConnections()
                self.handleClientRunnerExit(clientID: clientID, error: nil)
            } catch {
                logger.error(
                    "tunnel control client runtime task failed socket=\(self.socketPath, privacy: .public) details=\(renderTransportError(error), privacy: .public)"
                )
                self.handleClientRunnerExit(clientID: clientID, error: error)
            }
        }
        logger.notice(
            "tunnel control client runtime started socket=\(self.socketPath, privacy: .public)")
        return client
    }

    private func buildTransport() throws -> RuntimeTransport {
        let transport = try RuntimeTransport(
            target: .unixDomainSocket(path: socketPath, authority: tunnelControlAuthority),
            transportSecurity: .plaintext,
            config: .defaults { config in
                config.http2.authority = tunnelControlAuthority
            }
        )
        logger.notice(
            """
            configured tunnel control transport socket=\(self.socketPath, privacy: .public) \
            authority=\(tunnelControlAuthority, privacy: .public)
            """
        )
        return transport
    }

    private func handleClientRunnerExit(clientID: UUID, error: Error?) {
        guard activeClientID == clientID else {
            logger.notice("tunnel control client runtime exit ignored for stale client")
            return
        }

        activeClientID = nil
        client = nil
        runnerTask = nil
        shouldRetryInitialRPC = false

        if let error {
            logger.error(
                "tunnel control client runtime stopped with error socket=\(self.socketPath, privacy: .public) details=\(renderTransportError(error), privacy: .public)"
            )
        } else {
            logger.notice(
                "tunnel control client runtime stopped socket=\(self.socketPath, privacy: .public)")
        }
    }

    private func teardownClientRuntime(reason: String) {
        guard let client else {
            return
        }

        let runnerTask = self.runnerTask
        let clientID = activeClientID
        activeClientID = nil
        self.client = nil
        self.runnerTask = nil
        shouldRetryInitialRPC = false

        logger.notice(
            """
            tearing down tunnel control client runtime reason=\(reason, privacy: .public) \
            socket=\(self.socketPath, privacy: .public) clientConfigured=\(clientID != nil, privacy: .public)
            """
        )
        client.beginGracefulShutdown()
        runnerTask?.cancel()
    }

    private func decodeDiscovery(
        _ result: CTControlV1_StartRelayDiscoveryResponse.OneOf_Result?,
        missingPayloadMessage: String
    ) throws -> TunnelDiscoverySnapshot {
        switch result {
        case .discovery(let discovery):
            return TunnelDiscoverySnapshot(proto: discovery)
        case .error(let error):
            throw TunnelDaemonError(proto: error)
        case .none:
            throw TunnelDaemonError.transportFailure(missingPayloadMessage)
        }
    }

    private func decodeDiscovery(
        _ result: CTControlV1_StopRelayDiscoveryResponse.OneOf_Result?,
        missingPayloadMessage: String
    ) throws -> TunnelDiscoverySnapshot {
        switch result {
        case .discovery(let discovery):
            return TunnelDiscoverySnapshot(proto: discovery)
        case .error(let error):
            throw TunnelDaemonError(proto: error)
        case .none:
            throw TunnelDaemonError.transportFailure(missingPayloadMessage)
        }
    }

    private func decodeDiscovery(
        _ result: CTControlV1_ListRelayServicesResponse.OneOf_Result?,
        missingPayloadMessage: String
    ) throws -> TunnelDiscoverySnapshot {
        switch result {
        case .discovery(let discovery):
            return TunnelDiscoverySnapshot(proto: discovery)
        case .error(let error):
            throw TunnelDaemonError(proto: error)
        case .none:
            throw TunnelDaemonError.transportFailure(missingPayloadMessage)
        }
    }

    private func decodeDiscovery(
        _ result: CTControlV1_SelectRelayServiceResponse.OneOf_Result?,
        missingPayloadMessage: String
    ) throws -> TunnelDiscoverySnapshot {
        switch result {
        case .discovery(let discovery):
            return TunnelDiscoverySnapshot(proto: discovery)
        case .error(let error):
            throw TunnelDaemonError(proto: error)
        case .none:
            throw TunnelDaemonError.transportFailure(missingPayloadMessage)
        }
    }

    private func shouldRetryInitialRPCFailure(_ error: Error) -> Bool {
        guard let rpcError = error as? RPCError else {
            return false
        }

        switch rpcError.code {
        case .deadlineExceeded, .unavailable, .unknown, .internalError:
            return true
        default:
            return false
        }
    }
}

private func renderTransportError(_ error: Error) -> String {
    if let rpcError = error as? RPCError {
        let cause = rpcError.cause.map { String(describing: $0) }
        if let cause, !cause.isEmpty {
            return "rpc_code=\(rpcError.code) message=\(rpcError.message) cause=\(cause)"
        }
        return "rpc_code=\(rpcError.code) message=\(rpcError.message)"
    }

    return String(describing: error)
}

private func mapClientError(_ error: Error) -> TunnelDaemonError {
    if let daemonError = error as? TunnelDaemonError {
        return daemonError
    }
    if let rpcError = error as? RPCError {
        return TunnelDaemonError.rpcFailure(
            TunnelRPCFailure(
                code: String(describing: rpcError.code),
                message: rpcError.message,
                cause: rpcError.cause.map { String(describing: $0) }
            )
        )
    }
    return TunnelDaemonError.transportFailure(String(describing: error))
}

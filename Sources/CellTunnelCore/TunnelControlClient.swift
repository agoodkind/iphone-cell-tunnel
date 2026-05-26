import CellTunnelLog
import Foundation

private let logger = CellTunnelLog.logger(category: .daemon)

public let daemonControlMachServiceName = "io.goodkind.celltunneld.xpc"
public let daemonControlWireVersion = 1

public let defaultTunnelControlSocketPath = "/var/run/io.goodkind.celltunnel/control.sock"
public let tunnelControlSocketEnvironmentVariable = "CELL_TUNNEL_CONTROL_SOCKET"

public func resolvedTunnelControlSocketPath(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    guard let override = environment[tunnelControlSocketEnvironmentVariable] else {
        return defaultTunnelControlSocketPath
    }
    let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return defaultTunnelControlSocketPath
    }
    return trimmed
}

public enum DaemonControlRPC: String, Codable, Sendable {
    case status
    case check
    case startTunnel = "start-tunnel"
    case stopTunnel = "stop-tunnel"
    case startRelayDiscovery = "start-relay-discovery"
    case stopRelayDiscovery = "stop-relay-discovery"
    case listRelayServices = "list-relay-services"
    case selectRelayService = "select-relay-service"
}

public struct DaemonControlRequest: Codable, Sendable {
    public var version: Int
    public var rpc: DaemonControlRPC
    public var startSettings: TunnelStartSettings?
    public var serviceID: String?

    public init(
        rpc: DaemonControlRPC,
        startSettings: TunnelStartSettings? = nil,
        serviceID: String? = nil,
        version: Int = daemonControlWireVersion
    ) {
        self.version = version
        self.rpc = rpc
        self.startSettings = startSettings
        self.serviceID = serviceID
    }
}

public struct DaemonControlResponse: Codable, Sendable {
    public var version: Int
    public var status: TunnelDaemonStatusSnapshot?
    public var report: TunnelEnvironmentReport?
    public var discovery: TunnelDiscoverySnapshot?
    public var failure: DaemonControlResponseFailure?

    public init(
        status: TunnelDaemonStatusSnapshot? = nil,
        report: TunnelEnvironmentReport? = nil,
        discovery: TunnelDiscoverySnapshot? = nil,
        failure: DaemonControlResponseFailure? = nil,
        version: Int = daemonControlWireVersion
    ) {
        self.version = version
        self.status = status
        self.report = report
        self.discovery = discovery
        self.failure = failure
    }
}

public struct DaemonControlResponseFailure: Codable, Sendable {
    public var errorCode: TunnelControlErrorCode
    public var message: String

    public init(errorCode: TunnelControlErrorCode, message: String) {
        self.errorCode = errorCode
        self.message = message
    }
}

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

#if os(macOS)
    public actor TunnelControlClient: TunnelControlClientProtocol {
        private let machServiceName: String
        private var connection: NSXPCConnection?

        public init(
            socketPath: String = resolvedTunnelControlSocketPath(),
            machServiceName: String = daemonControlMachServiceName
        ) {
            _ = socketPath
            self.machServiceName = machServiceName
        }

        public func shutdown() {
            logger.notice(
                "tunnel control client shutdown requested service=\(self.machServiceName, privacy: .public)"
            )
            tearDownConnection(reason: "shutdown")
        }

        public func status() async throws -> TunnelDaemonStatusSnapshot {
            logger.notice("tunnel control client invoked rpc=status")
            let response = try await send(
                request: DaemonControlRequest(rpc: .status),
                operationName: "status"
            )
            return try requireStatus(from: response, operationName: "status")
        }

        public func check() async throws -> TunnelEnvironmentReport {
            logger.notice("tunnel control client invoked rpc=check")
            let response = try await send(
                request: DaemonControlRequest(rpc: .check),
                operationName: "check"
            )
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
            logger.notice("tunnel control client invoked rpc=start-tunnel")
            let response = try await send(
                request: DaemonControlRequest(rpc: .startTunnel, startSettings: settings),
                operationName: "startTunnel"
            )
            return try requireStatus(from: response, operationName: "startTunnel")
        }

        public func stopTunnel() async throws -> TunnelDaemonStatusSnapshot {
            logger.notice("tunnel control client invoked rpc=stop-tunnel")
            let response = try await send(
                request: DaemonControlRequest(rpc: .stopTunnel),
                operationName: "stopTunnel"
            )
            return try requireStatus(from: response, operationName: "stopTunnel")
        }

        public func startRelayDiscovery() async throws -> TunnelDiscoverySnapshot {
            logger.notice("tunnel control client invoked rpc=start-relay-discovery")
            let response = try await send(
                request: DaemonControlRequest(rpc: .startRelayDiscovery),
                operationName: "startRelayDiscovery"
            )
            return try requireDiscovery(from: response, operationName: "startRelayDiscovery")
        }

        public func stopRelayDiscovery() async throws -> TunnelDiscoverySnapshot {
            logger.notice("tunnel control client invoked rpc=stop-relay-discovery")
            let response = try await send(
                request: DaemonControlRequest(rpc: .stopRelayDiscovery),
                operationName: "stopRelayDiscovery"
            )
            return try requireDiscovery(from: response, operationName: "stopRelayDiscovery")
        }

        public func listRelayServices() async throws -> TunnelDiscoverySnapshot {
            logger.notice("tunnel control client invoked rpc=list-relay-services")
            let response = try await send(
                request: DaemonControlRequest(rpc: .listRelayServices),
                operationName: "listRelayServices"
            )
            return try requireDiscovery(from: response, operationName: "listRelayServices")
        }

        public func selectRelayService(serviceID: String) async throws -> TunnelDiscoverySnapshot {
            logger.notice(
                "tunnel control client invoked rpc=select-relay-service serviceID=\(serviceID, privacy: .public)"
            )
            let response = try await send(
                request: DaemonControlRequest(rpc: .selectRelayService, serviceID: serviceID),
                operationName: "selectRelayService"
            )
            return try requireDiscovery(from: response, operationName: "selectRelayService")
        }
    }

    extension TunnelControlClient {
        private func send(
            request: DaemonControlRequest,
            operationName: String
        ) async throws -> DaemonControlResponse {
            let conn = activeConnection()
            let requestData: Data
            do {
                requestData = try JSONEncoder().encode(request)
            } catch {
                throw TunnelDaemonError.transportFailure(
                    "failed to encode \(operationName) request: \(error.localizedDescription)"
                )
            }

            let responseData = try await performXPCCall(
                conn,
                requestData: requestData,
                operationName: operationName
            )

            let response: DaemonControlResponse
            do {
                response = try JSONDecoder().decode(
                    DaemonControlResponse.self, from: responseData)
            } catch {
                throw TunnelDaemonError.transportFailure(
                    "failed to decode \(operationName) response: \(error.localizedDescription)"
                )
            }

            try validate(responseVersion: response.version, operationName: operationName)
            logger.notice(
                """
                \(operationName) xpc completed \
                service=\(self.machServiceName, privacy: .public) \
                responseVersion=\(response.version, privacy: .public)
                """
            )
            return response
        }

        private func performXPCCall(
            _ conn: NSXPCConnection,
            requestData: Data,
            operationName: String
        ) async throws -> Data {
            let serviceName = machServiceName
            return try await withCheckedThrowingContinuation { continuation in
                let resumeOnce = ContinuationGuard(continuation)
                let errorHandler: @Sendable (Error) -> Void = { error in
                    logger.error(
                        """
                        \(operationName) xpc proxy error \
                        service=\(serviceName, privacy: .public) \
                        details=\(String(describing: error), privacy: .public)
                        """
                    )
                    resumeOnce.fail(TunnelDaemonError.daemonUnavailable(serviceName))
                }
                let proxy = conn.remoteObjectProxyWithErrorHandler(errorHandler)
                guard let typedProxy = proxy as? CellTunnelDaemonControlProtocol else {
                    resumeOnce.fail(
                        TunnelDaemonError.transportFailure("unexpected remote proxy type"))
                    return
                }
                typedProxy.handleControlRequest(requestData: requestData) { data, nsError in
                    if let nsError {
                        resumeOnce.fail(
                            TunnelDaemonError.transportFailure(nsError.localizedDescription))
                        return
                    }
                    guard let data else {
                        resumeOnce.fail(
                            TunnelDaemonError.transportFailure(
                                "\(operationName) returned empty response"))
                        return
                    }
                    resumeOnce.succeed(data)
                }
            }
        }

        private func activeConnection() -> NSXPCConnection {
            if let connection {
                return connection
            }
            let conn = NSXPCConnection(machServiceName: machServiceName)
            conn.remoteObjectInterface = NSXPCInterface(
                with: CellTunnelDaemonControlProtocol.self)
            let serviceName = machServiceName
            conn.invalidationHandler = {
                logger.notice(
                    """
                    tunnel control xpc connection invalidated \
                    service=\(serviceName, privacy: .public)
                    """
                )
            }
            conn.interruptionHandler = {
                logger.notice(
                    """
                    tunnel control xpc connection interrupted \
                    service=\(serviceName, privacy: .public)
                    """
                )
            }
            conn.resume()
            connection = conn
            logger.notice(
                "tunnel control xpc connection opened service=\(self.machServiceName, privacy: .public)"
            )
            return conn
        }

        private func tearDownConnection(reason: String) {
            guard let active = connection else {
                return
            }
            active.invalidate()
            connection = nil
            logger.notice(
                """
                tunnel control xpc connection torn down \
                reason=\(reason, privacy: .public) \
                service=\(self.machServiceName, privacy: .public)
                """
            )
        }

        private func validate(responseVersion: Int, operationName: String) throws {
            if responseVersion > daemonControlWireVersion {
                logger.error(
                    """
                    \(operationName) xpc response rejected \
                    receivedVersion=\(responseVersion, privacy: .public) \
                    supportedVersion=\(daemonControlWireVersion, privacy: .public)
                    """
                )
                throw TunnelDaemonError.transportFailure(
                    "unsupported daemon response version \(responseVersion)"
                )
            }
        }

        private func requireStatus(
            from response: DaemonControlResponse,
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
            from response: DaemonControlResponse,
            operationName: String
        ) throws -> TunnelDiscoverySnapshot {
            if let failure = response.failure {
                throw mapFailure(failure)
            }
            guard let discovery = response.discovery else {
                throw TunnelDaemonError.transportFailure("missing \(operationName) discovery payload")
            }
            return discovery
        }

        private func mapFailure(_ failure: DaemonControlResponseFailure) -> TunnelDaemonError {
            TunnelDaemonError.controlFailure(
                TunnelControlFailure(errorCode: failure.errorCode, message: failure.message)
            )
        }
    }

    private final class ContinuationGuard: @unchecked Sendable {
        private let continuation: CheckedContinuation<Data, Error>
        private let lock = NSLock()
        private var resolved = false

        init(_ continuation: CheckedContinuation<Data, Error>) {
            self.continuation = continuation
        }

        func succeed(_ value: Data) {
            lock.lock()
            if resolved {
                lock.unlock()
                return
            }
            resolved = true
            lock.unlock()
            continuation.resume(returning: value)
        }

        func fail(_ error: Error) {
            lock.lock()
            if resolved {
                lock.unlock()
                return
            }
            resolved = true
            lock.unlock()
            continuation.resume(throwing: error)
        }
    }
#endif

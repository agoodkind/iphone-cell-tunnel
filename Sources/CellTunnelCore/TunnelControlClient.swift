import CellTunnelLog
import Foundation

#if os(macOS)
    import XPC
#endif

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
        private let socketPath: String
        private var session: XPCSession?

        public init(
            socketPath: String = resolvedTunnelControlSocketPath(),
            machServiceName: String = daemonControlMachServiceName
        ) {
            self.socketPath = socketPath
            self.machServiceName = machServiceName
        }

        public func shutdown() {
            logger.notice(
                "tunnel control client shutdown requested service=\(self.machServiceName, privacy: .public)"
            )
            tearDownSession(reason: "shutdown")
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
            let activeSession = try activeSession()
            let response: DaemonControlResponse
            do {
                response = try await withCheckedThrowingContinuation { continuation in
                    do {
                        try activeSession.send(request) { (result: Result<DaemonControlResponse, any Error>) in
                            continuation.resume(with: result)
                        }
                    } catch {
                        logger.error(
                            """
                            \(operationName) xpc send dispatch failed \
                            service=\(self.machServiceName, privacy: .public) \
                            details=\(String(describing: error), privacy: .public)
                            """
                        )
                        continuation.resume(throwing: error)
                    }
                }
            } catch let error as TunnelDaemonError {
                logger.error(
                    """
                    \(operationName) xpc rethrowing tunnel daemon error \
                    service=\(self.machServiceName, privacy: .public) \
                    details=\(String(describing: error), privacy: .public)
                    """
                )
                throw error
            } catch let error as XPCRichError {
                tearDownSession(reason: "\(operationName)-xpc-error")
                logger.error(
                    """
                    \(operationName) xpc failed \
                    service=\(self.machServiceName, privacy: .public) \
                    details=\(String(describing: error), privacy: .public)
                    """
                )
                throw TunnelDaemonError.daemonUnavailable(self.machServiceName)
            } catch {
                tearDownSession(reason: "\(operationName)-error")
                logger.error(
                    """
                    \(operationName) xpc failed \
                    service=\(self.machServiceName, privacy: .public) \
                    details=\(String(describing: error), privacy: .public)
                    """
                )
                throw TunnelDaemonError.transportFailure(String(describing: error))
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

        private func activeSession() throws -> XPCSession {
            if let session {
                return session
            }
            do {
                let created = try XPCSession(machService: machServiceName)
                session = created
                logger.notice(
                    "tunnel control xpc session opened service=\(self.machServiceName, privacy: .public)"
                )
                return created
            } catch {
                logger.error(
                    """
                    tunnel control xpc session open failed \
                    service=\(self.machServiceName, privacy: .public) \
                    details=\(String(describing: error), privacy: .public)
                    """
                )
                throw TunnelDaemonError.daemonUnavailable(machServiceName)
            }
        }

        private func tearDownSession(reason: String) {
            guard let active = session else {
                return
            }
            active.cancel(reason: reason)
            session = nil
            logger.notice(
                """
                tunnel control xpc session torn down \
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
#endif

import CellTunnelCore
import CellTunnelLog
import Darwin
import Foundation

private let logger = CellTunnelLog.logger(category: .daemon)

@objc(CellTunnelHelperProtocol)
public protocol CellTunnelHelperProtocol {
    func openUtunDevice(
        requestData: Data,
        reply: @escaping (Data?, FileHandle?, NSError?) -> Void
    )
    func installRoutes(requestData: Data, reply: @escaping (Data?, NSError?) -> Void)
    func removeRoutes(requestData: Data, reply: @escaping (Data?, NSError?) -> Void)
}

enum HelperClientError: LocalizedError {
    case connectionFailed
    case encodingFailed(String)
    case decodingFailed(String)
    case helperFailure(HelperFailure)
    case missingResponse
    case missingFileDescriptor

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "helper client xpc connection failed"
        case .encodingFailed(let message):
            return "helper client encoding failed: \(message)"
        case .decodingFailed(let message):
            return "helper client decoding failed: \(message)"
        case .helperFailure(let failure):
            return "helper failure code=\(failure.code) message=\(failure.message)"
        case .missingResponse:
            return "helper client missing response payload"
        case .missingFileDescriptor:
            return "helper client missing utun file descriptor"
        }
    }
}

struct HelperUtunResult {
    let fileDescriptor: Int32
    let interfaceName: String
}

actor HelperClient {
    private let machServiceName: String
    private var connection: NSXPCConnection?

    init(machServiceName: String = helperMachServiceName) {
        self.machServiceName = machServiceName
    }

    func shutdown() {
        if let active = connection {
            active.invalidate()
            connection = nil
            logger.notice(
                "helper client connection torn down service=\(self.machServiceName, privacy: .public)"
            )
        }
    }

    func openUtunDevice() async throws -> HelperUtunResult {
        let active = ensureConnection()
        let request = HelperRequestEnvelope(
            rpc: .openUtunDevice,
            openUtun: HelperOpenUtunRequest()
        )
        let requestData = try encode(request)
        let machServiceName = self.machServiceName
        return try await withCheckedThrowingContinuation { continuation in
            let proxy = active.remoteObjectProxyWithErrorHandler { error in
                HelperClient.logProxyError(
                    error: error,
                    machServiceName: machServiceName
                )
                continuation.resume(throwing: HelperClientError.connectionFailed)
            }
            guard let typed = proxy as? any CellTunnelHelperProtocol else {
                continuation.resume(throwing: HelperClientError.connectionFailed)
                return
            }
            typed.openUtunDevice(requestData: requestData) { responseData, handle, nsError in
                if let nsError {
                    continuation.resume(throwing: nsError)
                    return
                }
                guard let responseData else {
                    continuation.resume(throwing: HelperClientError.missingResponse)
                    return
                }
                let envelope: HelperResponseEnvelope
                do {
                    envelope = try JSONDecoder().decode(
                        HelperResponseEnvelope.self,
                        from: responseData
                    )
                } catch {
                    continuation.resume(
                        throwing: HelperClientError.decodingFailed(String(describing: error))
                    )
                    return
                }
                if let failure = envelope.failure {
                    continuation.resume(throwing: HelperClientError.helperFailure(failure))
                    return
                }
                guard let openResponse = envelope.openUtun, let handle else {
                    continuation.resume(throwing: HelperClientError.missingFileDescriptor)
                    return
                }
                let duplicated = dup(handle.fileDescriptor)
                guard duplicated >= 0 else {
                    continuation.resume(throwing: HelperClientError.missingFileDescriptor)
                    return
                }
                let result = HelperUtunResult(
                    fileDescriptor: duplicated,
                    interfaceName: openResponse.interfaceName
                )
                continuation.resume(returning: result)
            }
        }
    }

    func installRoutes(
        _ prefixes: [HelperAddressPrefix],
        onInterface interfaceName: String
    ) async throws {
        let request = HelperRequestEnvelope(
            rpc: .installRoutes,
            installRoutes: HelperInstallRoutesRequest(
                interfaceName: interfaceName,
                prefixes: prefixes
            )
        )
        let requestData = try encode(request)
        try await dispatchVoid(requestData: requestData) { proxy, data, reply in
            proxy.installRoutes(requestData: data, reply: reply)
        }
    }

    func removeRoutes() async throws {
        let request = HelperRequestEnvelope(
            rpc: .removeRoutes,
            removeRoutes: HelperRemoveRoutesRequest()
        )
        let requestData = try encode(request)
        try await dispatchVoid(requestData: requestData) { proxy, data, reply in
            proxy.removeRoutes(requestData: data, reply: reply)
        }
    }

    private func dispatchVoid(
        requestData: Data,
        invocation:
            @Sendable @escaping (
                any CellTunnelHelperProtocol, Data, @escaping (Data?, NSError?) -> Void
            ) -> Void
    ) async throws {
        let active = ensureConnection()
        let machServiceName = self.machServiceName
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let proxy = active.remoteObjectProxyWithErrorHandler { error in
                HelperClient.logProxyError(
                    error: error,
                    machServiceName: machServiceName
                )
                continuation.resume(throwing: HelperClientError.connectionFailed)
            }
            guard let typed = proxy as? any CellTunnelHelperProtocol else {
                continuation.resume(throwing: HelperClientError.connectionFailed)
                return
            }
            invocation(typed, requestData) { responseData, nsError in
                if let nsError {
                    continuation.resume(throwing: nsError)
                    return
                }
                guard let responseData else {
                    continuation.resume(throwing: HelperClientError.missingResponse)
                    return
                }
                do {
                    let envelope = try JSONDecoder().decode(
                        HelperResponseEnvelope.self,
                        from: responseData
                    )
                    if let failure = envelope.failure {
                        continuation.resume(throwing: HelperClientError.helperFailure(failure))
                        return
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(
                        throwing: HelperClientError.decodingFailed(String(describing: error))
                    )
                }
            }
        }
    }

    private func encode(_ envelope: HelperRequestEnvelope) throws -> Data {
        do {
            return try JSONEncoder().encode(envelope)
        } catch {
            throw HelperClientError.encodingFailed(String(describing: error))
        }
    }

    private func ensureConnection() -> NSXPCConnection {
        if let active = connection {
            return active
        }
        let created = NSXPCConnection(machServiceName: machServiceName, options: [])
        created.remoteObjectInterface = NSXPCInterface(with: CellTunnelHelperProtocol.self)
        created.invalidationHandler = { [weak self] in
            logger.notice("helper client connection invalidated")
            Task { await self?.clearConnection() }
        }
        created.interruptionHandler = {
            logger.notice("helper client connection interrupted")
        }
        created.resume()
        connection = created
        logger.notice(
            "helper client connection opened service=\(self.machServiceName, privacy: .public)"
        )
        return created
    }

    private func clearConnection() {
        connection = nil
    }

    private static func logProxyError(error: Error, machServiceName: String) {
        logger.error(
            """
            helper client xpc remote proxy error \
            service=\(machServiceName, privacy: .public) \
            details=\(String(describing: error), privacy: .public)
            """
        )
    }
}

import CellTunnelCore
import CellTunnelLog
import Foundation

private let logger = CellTunnelLog.logger(category: .daemon)

let daemonControlRequestVersion = 1

final class ControlServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let state: DaemonState
    private let listener: NSXPCListener

    init(state: DaemonState) {
        self.state = state
        self.listener = NSXPCListener(machServiceName: daemonControlMachServiceName)
        super.init()
    }

    func start() {
        listener.delegate = self
        listener.resume()
        logger.notice(
            "control server started service=\(daemonControlMachServiceName, privacy: .public)"
        )
    }

    func stop() {
        listener.suspend()
        logger.notice("control server stopped")
    }

    func listener(
        _: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        let interface = NSXPCInterface(with: CellTunnelDaemonControlProtocol.self)
        newConnection.exportedInterface = interface
        let exportedObject = DaemonRPCExport(state: state)
        newConnection.exportedObject = exportedObject
        newConnection.invalidationHandler = {
            logger.notice("control server xpc connection invalidated")
        }
        newConnection.interruptionHandler = {
            logger.notice("control server xpc connection interrupted")
        }
        newConnection.resume()
        logger.notice(
            "control server xpc connection accepted pid=\(newConnection.processIdentifier, privacy: .public)"
        )
        return true
    }
}

private final class DaemonRPCExport: NSObject, CellTunnelDaemonControlProtocol {
    private let state: DaemonState

    init(state: DaemonState) {
        self.state = state
        super.init()
    }

    func handleControlRequest(
        requestData: Data,
        reply: @escaping (Data?, NSError?) -> Void
    ) {
        let request: DaemonControlRequest
        do {
            request = try JSONDecoder().decode(DaemonControlRequest.self, from: requestData)
        } catch {
            logger.error(
                "control server decode failed details=\(String(describing: error), privacy: .public)"
            )
            let nsError = NSError(
                domain: daemonControlErrorDomain,
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "failed to decode request: \(error.localizedDescription)"
                ]
            )
            reply(nil, nsError)
            return
        }

        guard request.version == daemonControlRequestVersion else {
            logger.error(
                """
                control server rejected unknown request version \
                version=\(request.version, privacy: .public) rpc=\(request.rpc.rawValue, privacy: .public)
                """
            )
            let response = DaemonControlResponse(
                failure: DaemonControlResponseFailure(
                    errorCode: .internal,
                    message: "unknown request version \(request.version)"
                )
            )
            replyEncoded(response, reply: reply)
            return
        }

        let capturedState = state
        let replyHolder = ReplyHolder(reply)
        Task {
            let response = await DaemonRPCExport.dispatch(
                rpc: request.rpc,
                request: request,
                state: capturedState
            )
            DaemonRPCExport.replyEncoded(response, reply: replyHolder.reply)
        }
    }

    private final class ReplyHolder: @unchecked Sendable {
        let reply: (Data?, NSError?) -> Void

        init(_ reply: @escaping (Data?, NSError?) -> Void) {
            self.reply = reply
        }
    }

    private static func replyEncoded(
        _ response: DaemonControlResponse,
        reply: (Data?, NSError?) -> Void
    ) {
        do {
            let data = try JSONEncoder().encode(response)
            reply(data, nil)
        } catch {
            logger.error(
                "control server encode failed details=\(String(describing: error), privacy: .public)"
            )
            let nsError = NSError(
                domain: daemonControlErrorDomain,
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "failed to encode response: \(error.localizedDescription)"
                ]
            )
            reply(nil, nsError)
        }
    }

    private func replyEncoded(
        _ response: DaemonControlResponse,
        reply: @escaping (Data?, NSError?) -> Void
    ) {
        DaemonRPCExport.replyEncoded(response, reply: reply)
    }

    private static func dispatch(
        rpc: DaemonControlRPC,
        request: DaemonControlRequest,
        state: DaemonState
    ) async -> DaemonControlResponse {
        do {
            switch rpc {
            case .status:
                let snapshot = await state.currentStatus()
                return DaemonControlResponse(status: snapshot)
            case .check:
                let report = await state.performCheck()
                return DaemonControlResponse(report: report)
            case .startTunnel:
                let settings = request.startSettings ?? TunnelStartSettings()
                let snapshot = try await state.startTunnel(settings: settings)
                return DaemonControlResponse(status: snapshot)
            case .stopTunnel:
                let snapshot = await state.stopTunnel()
                return DaemonControlResponse(status: snapshot)
            case .startRelayDiscovery:
                let snapshot = await state.startDiscovery()
                return DaemonControlResponse(discovery: snapshot)
            case .stopRelayDiscovery:
                let snapshot = await state.stopDiscovery()
                return DaemonControlResponse(discovery: snapshot)
            case .listRelayServices:
                let snapshot = await state.listDiscovery()
                return DaemonControlResponse(discovery: snapshot)
            case .selectRelayService:
                let serviceID = request.serviceID ?? ""
                let snapshot = await state.selectRelay(serviceID: serviceID)
                return DaemonControlResponse(discovery: snapshot)
            }
        } catch let error as TunnelDaemonError {
            return DaemonControlResponse(failure: failure(from: error))
        } catch {
            return DaemonControlResponse(
                failure: DaemonControlResponseFailure(
                    errorCode: .internal,
                    message: String(describing: error)
                )
            )
        }
    }

    private static func failure(from error: TunnelDaemonError) -> DaemonControlResponseFailure {
        switch error {
        case .controlFailure(let failure):
            return DaemonControlResponseFailure(
                errorCode: failure.errorCode,
                message: failure.message
            )
        case .daemonUnavailable(let socketPath):
            return DaemonControlResponseFailure(
                errorCode: .internal,
                message: "daemon unavailable socket=\(socketPath)"
            )
        case .rpcFailure(let failure):
            return DaemonControlResponseFailure(
                errorCode: .internal,
                message: "rpc \(failure.code) \(failure.message)"
            )
        case .transportFailure(let message):
            return DaemonControlResponseFailure(
                errorCode: .internal,
                message: message
            )
        case .usage(let message):
            return DaemonControlResponseFailure(
                errorCode: .unspecified,
                message: message
            )
        }
    }
}

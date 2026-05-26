import CellTunnelCore
import CellTunnelLog
import Foundation
import XPC

private let logger = CellTunnelLog.logger(category: .daemon)

let daemonControlMachServiceName = "io.goodkind.celltunneld.xpc"
let daemonControlRequestVersion = 1

final class ControlServer: @unchecked Sendable {
    private let state: DaemonState
    private var listener: XPCListener?

    init(state: DaemonState) {
        self.state = state
    }

    func start() throws {
        let activeState = state
        let nwListener = try XPCListener(
            service: daemonControlMachServiceName,
            targetQueue: .global(qos: .userInitiated)
        ) { request in
            request.accept { (message: DaemonControlRequest) -> (any Encodable)? in
                ControlServer.handle(message: message, state: activeState)
            }
        }
        try nwListener.activate()
        listener = nwListener
        logger.notice(
            "control server started service=\(daemonControlMachServiceName, privacy: .public)"
        )
    }

    func stop() {
        listener?.cancel()
        listener = nil
        logger.notice("control server stopped")
    }

    private static func handle(
        message: DaemonControlRequest,
        state: DaemonState
    ) -> DaemonControlResponse {
        guard message.version == daemonControlRequestVersion else {
            logger.error(
                """
                control server rejected unknown request version \
                version=\(message.version, privacy: .public) rpc=\(message.rpc.rawValue, privacy: .public)
                """
            )
            return DaemonControlResponse(
                failure: DaemonControlResponseFailure(
                    errorCode: .internal,
                    message: "unknown request version \(message.version)"
                )
            )
        }

        let semaphore = DispatchSemaphore(value: 0)
        let holder = ResponseHolder()
        Task {
            let value = await dispatch(rpc: message.rpc, request: message, state: state)
            holder.store(value)
            semaphore.signal()
        }
        semaphore.wait()
        return holder.value
    }

    private final class ResponseHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = DaemonControlResponse()

        func store(_ value: DaemonControlResponse) {
            lock.lock()
            stored = value
            lock.unlock()
        }

        var value: DaemonControlResponse {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
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

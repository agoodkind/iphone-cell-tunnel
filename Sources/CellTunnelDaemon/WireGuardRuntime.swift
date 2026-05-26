import CellTunnelLog
import Darwin
import Foundation
import WireGuardKitGo

private let logger = CellTunnelLog.logger(category: .daemon)

enum WireGuardRuntimeError: LocalizedError {
    case alreadyStarted
    case notStarted
    case turnOnFailed(Int32)
    case setConfigFailed(Int64)
    case getConfigFailed

    var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            return "wireguard runtime already started"
        case .notStarted:
            return "wireguard runtime not started"
        case .turnOnFailed(let code):
            return "wgTurnOn failed code=\(code)"
        case .setConfigFailed(let code):
            return "wgSetConfig failed code=\(code)"
        case .getConfigFailed:
            return "wgGetConfig returned null"
        }
    }
}

actor WireGuardRuntime {
    private var handle: Int32?

    func start(uapiConfig: String, utunFd: Int32) throws {
        guard handle == nil else {
            throw WireGuardRuntimeError.alreadyStarted
        }
        let returnedHandle = uapiConfig.withCString { cConfig in
            wgTurnOn(cConfig, utunFd)
        }
        guard returnedHandle >= 0 else {
            logger.error(
                """
                wireguard runtime turn-on failed code=\(returnedHandle, privacy: .public) \
                fd=\(utunFd, privacy: .public)
                """
            )
            throw WireGuardRuntimeError.turnOnFailed(returnedHandle)
        }
        handle = returnedHandle
        logger.notice(
            """
            wireguard runtime started handle=\(returnedHandle, privacy: .public) \
            fd=\(utunFd, privacy: .public)
            """
        )
    }

    func stop() {
        guard let activeHandle = handle else {
            return
        }
        wgTurnOff(activeHandle)
        handle = nil
        logger.notice(
            "wireguard runtime stopped handle=\(activeHandle, privacy: .public)"
        )
    }

    func updateConfig(_ uapiConfig: String) throws {
        guard let activeHandle = handle else {
            throw WireGuardRuntimeError.notStarted
        }
        let status = uapiConfig.withCString { cConfig in
            wgSetConfig(activeHandle, cConfig)
        }
        guard status == 0 else {
            logger.error(
                """
                wireguard runtime set-config failed handle=\(activeHandle, privacy: .public) \
                code=\(status, privacy: .public)
                """
            )
            throw WireGuardRuntimeError.setConfigFailed(status)
        }
        logger.notice(
            "wireguard runtime configuration updated handle=\(activeHandle, privacy: .public)"
        )
    }

    func currentConfig() throws -> String {
        guard let activeHandle = handle else {
            throw WireGuardRuntimeError.notStarted
        }
        guard let cConfig = wgGetConfig(activeHandle) else {
            throw WireGuardRuntimeError.getConfigFailed
        }
        defer { free(cConfig) }
        return String(cString: cConfig)
    }

    var isRunning: Bool {
        handle != nil
    }
}

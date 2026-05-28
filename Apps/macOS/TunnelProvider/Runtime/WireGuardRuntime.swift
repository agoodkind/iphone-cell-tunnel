import CellTunnelLog
import Foundation
import NetworkExtension
import WireGuardKit

private let logger = CellTunnelLog.logger(category: .daemon)

enum WireGuardRuntimeError: LocalizedError {
    case adapterFailure(WireGuardAdapterError)
    case alreadyStarted
    case notStarted

    var errorDescription: String? {
        switch self {
        case .adapterFailure(let detail):
            return "tunnel runtime adapter failure detail=\(String(describing: detail))"
        case .alreadyStarted:
            return "tunnel runtime already started"
        case .notStarted:
            return "tunnel runtime not started"
        }
    }
}

actor WireGuardRuntime {
    private var adapter: WireGuardAdapter?
    private var relayBind: WireGuardRelayBindBridge?
    private var didStart = false

    func start(
        tunnelConfiguration: TunnelConfiguration,
        relayBind: WireGuardRelayBindBridge,
        provider: NEPacketTunnelProvider
    ) async throws {
        guard !didStart else {
            throw WireGuardRuntimeError.alreadyStarted
        }
        let adapter = WireGuardAdapter(with: provider) { logLevel, line in
            Self.relayAdapterDiagnosticLine(logLevel: logLevel, line: line)
        }
        self.adapter = adapter
        self.relayBind = relayBind
        logger.notice("tunnel runtime adapter start scheduled")
        let outcome = await withCheckedContinuation { continuation in
            adapter.start(
                tunnelConfiguration: tunnelConfiguration,
                relayBind: relayBind
            ) { adapterError in
                continuation.resume(returning: adapterError)
            }
        }
        if let outcome {
            logger.error(
                "tunnel runtime adapter start failed detail=\(String(describing: outcome), privacy: .public)"
            )
            throw WireGuardRuntimeError.adapterFailure(outcome)
        }
        didStart = true
        logger.notice("tunnel runtime start completed")
    }

    func stop() async {
        guard let adapter else {
            return
        }
        await withCheckedContinuation { continuation in
            adapter.stop { stopError in
                if let stopError {
                    logger.error(
                        "tunnel runtime stop returned errorDetail=\(String(describing: stopError), privacy: .public)"
                    )
                }
                continuation.resume()
            }
        }
        self.adapter = nil
        relayBind = nil
        didStart = false
        logger.notice("tunnel runtime stop completed")
    }

    var isRunning: Bool {
        didStart
    }

    private static func relayAdapterDiagnosticLine(
        logLevel: WireGuardLogLevel,
        line: String
    ) {
        switch logLevel {
        case .error:
            logger.error(
                "tunnel runtime backend diagnostic level=error line=\(line, privacy: .public)"
            )
        case .verbose:
            logger.debug(
                "tunnel runtime backend diagnostic level=verbose line=\(line, privacy: .public)"
            )
        }
    }

}

import CellTunnelLog
import Darwin
import Foundation

private let logger = CellTunnelLog.logger(category: .daemon)

CellTunnelLog.bootstrap()
logger.notice("celltunneld booting")

let daemonState = DaemonState()
let controlServer = ControlServer(state: daemonState)

do {
    try controlServer.start()
} catch {
    logger.error(
        "celltunneld control server start failed error=\(String(describing: error), privacy: .public)"
    )
    exit(EXIT_FAILURE)
}

let signalQueue = DispatchQueue(label: "io.goodkind.celltunneld.signals")
var signalSources: [DispatchSourceSignal] = []

func installSignalHandler(_ signalNumber: Int32) -> DispatchSourceSignal {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: signalQueue)
    source.setEventHandler {
        logger.notice("celltunneld received signal=\(signalNumber, privacy: .public); shutting down")
        Task {
            await daemonState.shutdown()
            controlServer.stop()
            logger.notice("celltunneld exit signal=\(signalNumber, privacy: .public)")
            exit(EXIT_SUCCESS)
        }
    }
    source.resume()
    return source
}

signalSources.append(installSignalHandler(SIGINT))
signalSources.append(installSignalHandler(SIGTERM))

logger.notice("celltunneld ready")
dispatchMain()

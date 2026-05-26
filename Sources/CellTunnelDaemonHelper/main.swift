import CellTunnelLog
import Darwin
import Foundation

private let logger = CellTunnelLog.logger(category: .daemon)

CellTunnelLog.bootstrap()
logger.notice("celltunneldhelperd booting")

let helperState = HelperState()
let helperServer = HelperControlServer(state: helperState)

helperServer.start()

let helperSignalQueue = DispatchQueue(label: "io.goodkind.celltunneldhelperd.signals")
var helperSignalSources: [DispatchSourceSignal] = []

func installHelperSignalHandler(_ signalNumber: Int32) -> DispatchSourceSignal {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: helperSignalQueue)
    source.setEventHandler {
        logger.notice(
            "celltunneldhelperd received signal=\(signalNumber, privacy: .public); shutting down"
        )
        helperState.shutdown()
        helperServer.stop()
        logger.notice("celltunneldhelperd exit signal=\(signalNumber, privacy: .public)")
        exit(EXIT_SUCCESS)
    }
    source.resume()
    return source
}

helperSignalSources.append(installHelperSignalHandler(SIGINT))
helperSignalSources.append(installHelperSignalHandler(SIGTERM))

logger.notice("celltunneldhelperd ready")
dispatchMain()

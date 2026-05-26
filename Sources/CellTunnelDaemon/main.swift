import CellTunnelLog
import Darwin
import Foundation

private let logger = CellTunnelLog.logger(category: .daemon)

private func emitDiagnostic(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

CellTunnelLog.bootstrap()
logger.notice("celltunneld booting")
emitDiagnostic("celltunneld step=boot")

let daemonState = DaemonState()

emitDiagnostic("celltunneld step=state-init-done")

let controlServer = ControlServer(state: daemonState)

emitDiagnostic("celltunneld step=control-server-init-done")
controlServer.start()
emitDiagnostic("celltunneld step=control-server-start-ok")

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
emitDiagnostic("celltunneld step=ready entering dispatchMain")
dispatchMain()

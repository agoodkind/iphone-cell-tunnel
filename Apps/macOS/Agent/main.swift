import CellTunnelCore
import CellTunnelLog
import Darwin
import Dispatch
import Foundation

private let logger = CellTunnelLog.logger(category: .daemon)

private let agentIdleTimeoutSeconds: Double = 60

final class AgentRuntime: @unchecked Sendable {
    private let listener = NSXPCListener.anonymous()
    private let controller = AgentTunnelController()
    private let idleQueue = DispatchQueue(label: "io.goodkind.celltunnel.agent.idle")
    private var idleTimer: DispatchSourceTimer?
    private var server: AgentXPCServer?

    func start() throws {
        let server = AgentXPCServer(controller: controller) { [weak self] in
            self?.resetIdleTimer()
        }
        self.server = server
        listener.delegate = server
        listener.resume()
        try publishEndpoint()
        resetIdleTimer()
        logger.notice("agent listener resumed path=\(agentControlEndpointPath, privacy: .public)")
    }

    func shutdown(reason: String) {
        logger.notice("agent shutting down reason=\(reason, privacy: .public)")
        removeEndpointFile()
        listener.invalidate()
    }

    private func publishEndpoint() throws {
        let endpoint = listener.endpoint
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: endpoint,
            requiringSecureCoding: true
        )
        try data.write(to: URL(fileURLWithPath: agentControlEndpointPath), options: .atomic)
        logger.notice("agent endpoint published path=\(agentControlEndpointPath, privacy: .public)")
    }

    private func removeEndpointFile() {
        do {
            try FileManager.default.removeItem(atPath: agentControlEndpointPath)
            logger.notice("agent endpoint file removed")
        } catch {
            logger.notice(
                """
                agent endpoint file remove skipped \
                path=\(agentControlEndpointPath, privacy: .public) \
                details=\(String(describing: error), privacy: .public) \
                recovery=ignore-missing-file
                """
            )
        }
    }

    private func resetIdleTimer() {
        idleQueue.async { [weak self] in
            guard let self else {
                return
            }
            idleTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: idleQueue)
            timer.schedule(deadline: .now() + agentIdleTimeoutSeconds)
            timer.setEventHandler { [weak self] in
                logger.notice("agent idle timeout reached, terminating")
                self?.shutdown(reason: "idle-timeout")
                exit(EXIT_SUCCESS)
            }
            timer.resume()
            idleTimer = timer
        }
    }
}

nonisolated(unsafe) var signalSourceRetention: [DispatchSourceSignal] = []
let agentRuntime = AgentRuntime()

CellTunnelLog.bootstrap()
logger.notice("agent boot")

let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

interruptSource.setEventHandler {
    agentRuntime.shutdown(reason: "SIGINT")
    exit(EXIT_SUCCESS)
}

terminateSource.setEventHandler {
    agentRuntime.shutdown(reason: "SIGTERM")
    exit(EXIT_SUCCESS)
}

interruptSource.resume()
terminateSource.resume()
signalSourceRetention = [interruptSource, terminateSource]

do {
    try agentRuntime.start()
} catch {
    logger.error(
        "agent failed to start details=\(String(describing: error), privacy: .public) recovery=exit-failure"
    )
    exit(EXIT_FAILURE)
}

dispatchMain()

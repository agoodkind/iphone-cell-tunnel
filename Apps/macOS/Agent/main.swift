//
//  main.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-27.
//  Copyright © 2026
//

import CellTunnelCore
import CellTunnelLog
import Darwin
import Dispatch
import Foundation
import ServiceManagement

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .daemon)

private let agentIdleTimeoutSeconds: Double = 60

// MARK: - AgentRuntime

final class AgentRuntime: @unchecked Sendable {
    private let listener = NSXPCListener(machServiceName: agentMachServiceName)
    private let controller = AgentTunnelController()
    private let idleQueue = DispatchQueue(label: "io.goodkind.celltunnel.agent.idle")
    private var idleTimer: DispatchSourceTimer?
    private var relayActive = false
    private var server: AgentXPCServer?
    private var sessionListener: AgentSessionListener?

    // MARK: - Lifecycle

    func start() {
        registerLaunchAgentIfNeeded()
        let server = AgentXPCServer(controller: controller) { [weak self] in
            self?.resetIdleTimer()
        }
        self.server = server
        listener.delegate = server
        listener.resume()
        // The modern libxpc listener serves the same control protocol to the Mac
        // Catalyst app, which cannot open an NSXPCConnection to a mach service.
        let sessionListener = AgentSessionListener(controller: controller) { [weak self] in
            self?.resetIdleTimer()
        }
        self.sessionListener = sessionListener
        sessionListener.start()
        resetIdleTimer()
        wireRelayActivityHold()
        logger.notice(
            "agent listener resumed machService=\(agentMachServiceName, privacy: .public)"
        )
    }

    // Hands the controller a hold so the agent does not idle-terminate while it
    // hosts an active relay. The agent owns the relay bridge in memory, so exiting
    // mid-relay would kill the bridge and strand the iPhone link.
    private func wireRelayActivityHold() {
        let controller = self.controller
        let runtime = self
        Task {
            await controller.setRelayActiveHandler { [weak runtime] active in
                runtime?.setRelayActive(active)
            }
        }
    }

    func shutdown(reason: String) {
        logger.notice("agent shutting down reason=\(reason, privacy: .public)")
        listener.invalidate()
    }

    private func registerLaunchAgentIfNeeded() {
        if #available(macOS 13.0, *) {
            let service = SMAppService.agent(plistName: agentLaunchAgentPlistName)
            logger.notice(
                """
                agent SMAppService status pre \
                raw=\(service.status.rawValue, privacy: .public) \
                desc=\(String(describing: service.status), privacy: .public)
                """
            )
            switch service.status {
            case .notRegistered, .notFound:
                // Apple docs say .notRegistered is the fresh-install case, but the
                // framework empirically returns .notFound (rawValue 3) for a freshly
                // installed app whose plist is present and sealed. Attempt register
                // in either case and log the resulting status.
                do {
                    try service.register()
                    logger.notice(
                        """
                        agent SMAppService register ok post \
                        raw=\(service.status.rawValue, privacy: .public) \
                        desc=\(String(describing: service.status), privacy: .public)
                        """
                    )
                } catch {
                    logger.error(
                        """
                        agent SMAppService register failed \
                        details=\(String(describing: error), privacy: .public) \
                        recovery=continue-listening
                        """
                    )
                }
            case .enabled:
                logger.notice("agent SMAppService already enabled")
            case .requiresApproval:
                logger.notice(
                    "agent SMAppService requiresApproval; enable in System Settings, General, Login Items"
                )
            @unknown default:
                logger.error(
                    """
                    agent SMAppService unknown status \
                    rawValue=\(service.status.rawValue, privacy: .public)
                    """
                )
            }
        }
    }

    // MARK: - Relay activity hold

    /// Holds or releases the idle countdown. While the relay is active the agent
    /// must not exit, so the timer is cancelled and not rescheduled; when the
    /// relay stops the 60 second countdown resumes.
    func setRelayActive(_ active: Bool) {
        idleQueue.async { [weak self] in
            guard let self else {
                return
            }
            relayActive = active
            if active {
                idleTimer?.cancel()
                idleTimer = nil
                logger.notice("agent idle timer held: relay active")
            } else {
                logger.notice("agent idle timer resumed: relay inactive")
                scheduleIdleTimerOnQueue()
            }
        }
    }

    // MARK: - Idle timer

    private func resetIdleTimer() {
        idleQueue.async { [weak self] in
            self?.scheduleIdleTimerOnQueue()
        }
    }

    /// Runs only on `idleQueue`. Does nothing while the relay-active hold is set,
    /// so the agent stays alive for the life of the relay.
    private func scheduleIdleTimerOnQueue() {
        idleTimer?.cancel()
        guard !relayActive else {
            idleTimer = nil
            return
        }
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

agentRuntime.start()

dispatchMain()

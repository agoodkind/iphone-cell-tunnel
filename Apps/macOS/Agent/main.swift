//
//  main.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-27.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Darwin
import Dispatch
import Foundation
import ServiceManagement

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .daemon)

// MARK: - AgentRuntime

/// Runs for as long as launchd keeps it loaded.
///
/// The agent does not stop itself. It owns the relay bridge, the Bonjour records
/// the iPhone browses for, and the live link set, none of which survive the
/// process or can be rebuilt without it. The iPhone reaches the agent over the
/// local network and the packet tunnel over loopback, so neither can start it,
/// and only the Mac app and the command-line tool can. A self-imposed exit would
/// therefore end sessions that nothing present could restore.
final class AgentRuntime: @unchecked Sendable {
  private let controller: AgentTunnelController
  private var sessionListener: AgentSessionListener?

  init(controller: AgentTunnelController) {
    self.controller = controller
  }

  // MARK: - Lifecycle

  func start() {
    registerLaunchAgentIfNeeded()
    // The libxpc listener serves the control protocol to every client: the
    // command-line tool and the Mac app both dial it with the libxpc session
    // API. A Mac Catalyst app cannot open an NSXPCConnection to a mach service,
    // so this is the single transport.
    let listener = AgentSessionListener(controller: controller)
    self.sessionListener = listener
    listener.start()
    logger.notice(
      "agent listener resumed machService=\(agentMachServiceName, privacy: .public)"
    )
  }

  /// Tears the relay down before the process goes away.
  ///
  /// The packet tunnel is a separate process and outlives this one, so an exit
  /// that only closed the listener would leave its routes and resolver pointing
  /// at a bridge that no longer exists. Traffic would then be dropped rather than
  /// fall back to the physical interface, which is silent and looks like a dead
  /// network rather than a stopped tunnel.
  func shutdown(reason: String) async {
    logger.notice("agent shutting down reason=\(reason, privacy: .public)")
    await controller.stopControlListener()
    sessionListener?.stop()
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
        registerLaunchAgent(service)
      case .enabled:
        // A replaced app bundle can leave launchd holding stale metadata for the
        // previously registered helper. Re-registering while enabled refreshes the
        // launchd wiring to the current bundle contents.
        logger.notice("agent SMAppService enabled; refreshing registration")
        registerLaunchAgent(service)
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

  private func registerLaunchAgent(_ service: SMAppService) {
    // Apple docs say .notRegistered is the fresh-install case, but the framework
    // empirically returns .notFound (rawValue 3) for a freshly installed app whose
    // plist is present and sealed. Attempt register in either case, and also when
    // enabled so a replaced bundle refreshes launchd's cached helper metadata.
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
  }

}

// MARK: - Composition root

/// Builds the agent graph as locals and runs the dispatch main loop. Nothing is a
/// module global: the runtime, the collaborators it injects, and the signal sources
/// all live for the life of the process inside this call, which never returns.
private func runAgent() -> Never {
  CellTunnelLog.bootstrap()
  logger.notice("agent boot")

  let relayBridge = AgentRelayBridge()
  let relayBrowser = RelayDeviceBrowser()
  let controller = AgentTunnelController(relayBridge: relayBridge, relayBrowser: relayBrowser)
  let agentRuntime = AgentRuntime(controller: controller)

  let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
  let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

  signal(SIGINT, SIG_IGN)
  signal(SIGTERM, SIG_IGN)

  // Teardown is asynchronous, so the exit waits for it. Exiting immediately would
  // leave the packet tunnel holding routes to a bridge that is already gone.
  interruptSource.setEventHandler {
    Task {
      await agentRuntime.shutdown(reason: "SIGINT")
      exit(EXIT_SUCCESS)
    }
  }

  terminateSource.setEventHandler {
    Task {
      await agentRuntime.shutdown(reason: "SIGTERM")
      exit(EXIT_SUCCESS)
    }
  }

  interruptSource.resume()
  terminateSource.resume()

  agentRuntime.start()

  // Assert, without mutating the library, that the running tunnel's stamped config id
  // agrees with the library's active selection, surfacing any drift loudly on status.
  Task { await controller.assertRunningConfigMatchesLibrary() }

  dispatchMain()
}

runAgent()

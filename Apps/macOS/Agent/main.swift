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

private let agentIdleTimeoutSeconds: Double = 60
/// The countdown while the agent is advertising and no phone has connected. Long
/// enough that a person can pick up their phone, unlock it, and open the app, and
/// short enough that an attempt nobody completes still releases the agent.
private let agentAdvertisingTimeoutSeconds: Double = 900
/// How long to wait when a relay is hosted but its phone link is momentarily
/// down, which is the usual shape of a failover between interfaces.
private let agentLinkGraceSeconds: Double = 30
/// How many of those short waits to allow before deciding the phone is gone.
private let agentLinkGraceRounds = 4

// MARK: - AgentRuntime

final class AgentRuntime: @unchecked Sendable {
  private let controller: AgentTunnelController
  private let idleQueue = DispatchQueue(label: "io.goodkind.celltunnel.agent.idle")
  private var idleTimer: DispatchSourceTimer?
  private var work: AgentWork = .idle
  /// Asked before exiting, so neither a bridge that failed after reporting itself
  /// hosted nor a phone that walked away can keep the agent alive with nothing to
  /// protect.
  private var phoneToStrandCheck: (@Sendable () async -> Bool)?
  /// Asked alongside it, so a hosted relay in a brief link gap is told apart from
  /// one whose phone has actually gone.
  private var relayHostedCheck: (@Sendable () async -> Bool)?
  /// Bumped on every arming, so a check still in flight from an earlier expiry
  /// cannot exit after a newer wait has begun.
  private var countdownGeneration: UInt64 = 0
  /// Consecutive short waits already spent on a hosted relay with no phone link.
  private var linkGraceRounds = 0
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
    let listener = AgentSessionListener(controller: controller) { [weak self] in
      self?.resetIdleTimer()
    }
    self.sessionListener = listener
    resetIdleTimer()
    // The hold is installed before the listener serves anything. Serving first
    // leaves a window where the earliest request signals work in flight into a
    // handler that is not there yet, and that signal is never repeated, so the
    // agent would idle out mid-pairing exactly as it did before this hold existed.
    let heldController = self.controller
    let runtime = self
    Task {
      await heldController.setAgentWorkHandler { [weak runtime] work in
        runtime?.setAgentWork(work)
      }
      let checkedController = heldController
      // Confined to idleQueue like every other mutable field here, because the
      // timer handler reads them from that queue and this runs on an arbitrary one.
      runtime.idleQueue.async {
        runtime.phoneToStrandCheck = { await checkedController.hasPhoneToStrand() }
        runtime.relayHostedCheck = { await checkedController.isRelayHosted() }
      }
      listener.start()
      logger.notice(
        "agent listener resumed machService=\(agentMachServiceName, privacy: .public)"
      )
    }
  }

  func shutdown(reason: String) {
    logger.notice("agent shutting down reason=\(reason, privacy: .public)")
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

  // MARK: - Idle hold

  /// Records what the agent is doing and re-arms the countdown to match.
  func setAgentWork(_ newWork: AgentWork) {
    idleQueue.async { [weak self] in
      guard let self else {
        return
      }
      work = newWork
      logger.notice(
        "agent idle countdown rescheduled work=\(String(describing: newWork), privacy: .public)")
      scheduleIdleTimerOnQueue()
    }
  }

  // MARK: - Idle timer

  private func resetIdleTimer() {
    idleQueue.async { [weak self] in
      self?.scheduleIdleTimerOnQueue()
    }
  }

  /// Runs only on `idleQueue`. The countdown is always armed, and hosting only
  /// lengthens it, because a timer that is never armed cannot recover if the state
  /// it trusted turns out to be stale. Whether the agent actually exits is decided
  /// when the timer fires, by asking whether a relay is hosted at that moment: a
  /// live relay reschedules, since the agent owns that bridge in memory and the
  /// phone's link surfaces no drop, while a stale claim exits as it should.
  private func scheduleIdleTimerOnQueue() {
    let timeout = work.idleCountdownSeconds(
      idle: agentIdleTimeoutSeconds, advertising: agentAdvertisingTimeoutSeconds)
    armTimerOnQueue(after: timeout)
  }

  /// Runs only on `idleQueue`. Each arming takes the next generation, so an answer
  /// that arrives after a newer wait began can tell, and leaves the decision to
  /// that newer wait rather than acting on facts gathered before it.
  private func armTimerOnQueue(after timeout: Double) {
    idleTimer?.cancel()
    countdownGeneration &+= 1
    let timer = DispatchSource.makeTimerSource(queue: idleQueue)
    timer.schedule(deadline: .now() + timeout)
    timer.setEventHandler { [weak self] in
      self?.exitIfNoPhoneToStrand()
    }
    timer.resume()
    idleTimer = timer
  }

  /// Asks the controller what is true right now, rather than reading the work
  /// state recorded when a start began, because a bridge can fail and a phone can
  /// leave with nothing announcing either.
  private func exitIfNoPhoneToStrand() {
    let strandCheck = phoneToStrandCheck
    let hostedCheck = relayHostedCheck
    // Arm the next countdown before asking, so a question that never comes back
    // leaves a timer running rather than no timer at all. The answer carries the
    // generation it was asked under, so this re-arming supersedes a late reply
    // rather than racing it.
    armTimerOnQueue(after: agentLinkGraceSeconds)
    let askedUnder = countdownGeneration
    Task { [weak self] in
      let strands = await strandCheck?() ?? false
      let hosted = await hostedCheck?() ?? false
      guard let self else {
        return
      }
      idleQueue.async {
        self.decideExitOnQueue(generation: askedUnder, strands: strands, hosted: hosted)
      }
    }
  }

  /// Runs only on `idleQueue`, so the generation it compares cannot change under
  /// it. A newer generation means a request arrived while the check was in flight,
  /// and that newer wait is the one entitled to decide.
  private func decideExitOnQueue(generation: UInt64, strands: Bool, hosted: Bool) {
    guard generation == countdownGeneration else {
      return
    }
    if strands {
      linkGraceRounds = 0
      logger.notice("agent countdown reached, phone linked, waiting again")
      scheduleIdleTimerOnQueue()
      return
    }
    // A hosted relay whose phone link is momentarily down is usually failing over
    // between interfaces, which recovers in seconds. Exiting then would kill a
    // working bridge, so wait briefly a bounded number of times before deciding.
    if hosted, linkGraceRounds < agentLinkGraceRounds {
      linkGraceRounds += 1
      logger.notice("agent countdown reached, relay hosted with no link, waiting briefly")
      armTimerOnQueue(after: agentLinkGraceSeconds)
      return
    }
    logger.notice("agent countdown reached, nothing to strand, terminating")
    shutdown(reason: "idle-timeout")
    exit(EXIT_SUCCESS)
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

  agentRuntime.start()

  // Assert, without mutating the library, that the running tunnel's stamped config id
  // agrees with the library's active selection, surfacing any drift loudly on status.
  Task { await controller.assertRunningConfigMatchesLibrary() }

  dispatchMain()
}

runAgent()

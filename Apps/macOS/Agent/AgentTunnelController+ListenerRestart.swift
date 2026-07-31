//
//  AgentTunnelController+ListenerRestart.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-31.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation

private let logger = CellTunnelLog.logger(category: .daemon)

// MARK: - Control listener rebuilding

extension AgentTunnelController {
  /// Rebuilds the control listener when it stops serving, so the Mac does not go
  /// quietly undiscoverable.
  ///
  /// The listener publishes the record the iPhone browses for and binds a fixed port,
  /// which a previous instance or an interface change can take away while the agent
  /// stays healthy in every other respect. Nothing else notices, and the user sees no
  /// peers with no error to act on.
  ///
  /// The failed listener is dropped before anything else, because the start path
  /// returns early whenever a listener object exists and would otherwise refuse every
  /// attempt to replace it.
  func applyListenerServingChange(_ isServing: Bool) async {
    guard !isServing else {
      listenerRestart.recordSuccess()
      return
    }
    await controlListener?.stop()
    controlListener = nil
    publicExchange = nil
    switch listenerRestart.recordFailure() {
    case .giveUp:
      logger.error(
        """
        agent control listener not rebuilt reason=repeated-failures \
        recovery=await-client-request
        """
      )
    case .retry(let afterMilliseconds):
      logger.notice(
        "agent control listener rebuilding delay_ms=\(afterMilliseconds, privacy: .public)"
      )
      scheduleRebuild(afterMilliseconds: afterMilliseconds)
    }
  }

  /// Cancels a pending rebuild, so a teardown is not followed by a listener the
  /// caller just asked to be rid of.
  func cancelListenerRebuild() {
    listenerRestartTimer?.cancel()
    listenerRestartTimer = nil
  }

  /// Waits on a one-shot timer, then builds a replacement listener.
  private func scheduleRebuild(afterMilliseconds: Int) {
    listenerRestartTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(deadline: .now() + .milliseconds(afterMilliseconds))
    timer.setEventHandler { @Sendable [weak self] in
      Task { await self?.rebuildControlListener() }
    }
    timer.resume()
    listenerRestartTimer = timer
  }

  /// Builds a replacement listener, reporting a failure that leaves none.
  ///
  /// A rebuild that throws does not schedule another one itself. Either the listener
  /// binds and fails again, which reports through the serving handler and continues
  /// the run, or nothing was built and the next client request tries again.
  private func rebuildControlListener() async {
    listenerRestartTimer = nil
    do {
      try await ensureControlListenerStarted()
    } catch {
      logger.error(
        """
        agent control listener rebuild failed \
        details=\(String(describing: error), privacy: .public) \
        recovery=await-client-request
        """
      )
    }
  }
}

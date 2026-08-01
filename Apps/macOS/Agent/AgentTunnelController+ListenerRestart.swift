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
  /// Every listener carries the generation it was built in, and a report from an older
  /// generation is ignored. Without that, a listener that failed can tear down the
  /// replacement that already took its place, because the report says only that some
  /// listener stopped serving and arrives after the swap.
  func applyListenerServingChange(generation: Int, isServing: Bool) async {
    guard generation == controlListenerGeneration else {
      return
    }
    guard !isServing else {
      // A rebuild that binds does not clear the run of failures. A listener that binds
      // and fails repeatedly would otherwise reset the count on every bind, and the
      // bound on rebuilding would never be reached.
      if !controlListenerFromRebuild {
        listenerRestart.recordSuccess()
      }
      return
    }
    // Retire this generation before anything awaits, so a report about the listener
    // being retired here cannot arrive later and tear down its replacement.
    controlListenerGeneration += 1
    let failed = controlListener
    controlListener = nil
    publicExchange = nil
    // The peers belonged to the listener that just died, so leaving them in the
    // snapshot would report an iPhone as connected over a link that is gone.
    connectedPeers.withLock { $0 = [] }
    peerName.withLock { $0 = nil }
    await failed?.stop()
    switch listenerRestart.recordFailure() {
    case .giveUp:
      logger.error(
        """
        agent control listener not rebuilt reason=repeated-failures \
        recovery=celltunnelctl-start-discovery
        """
      )
    case .retry(let afterMilliseconds):
      logger.notice(
        "agent control listener rebuilding delay_ms=\(afterMilliseconds, privacy: .public)"
      )
      scheduleRebuild(afterMilliseconds: afterMilliseconds, generation: controlListenerGeneration)
    }
  }

  /// Cancels a pending rebuild, so a teardown is not followed by a listener the
  /// caller just asked to be rid of.
  ///
  /// Retiring the generation is what makes the cancel reliable. A timer whose handler
  /// already began running cannot be called back, so the rebuild it starts is stopped
  /// by finding its generation stale rather than by the cancel.
  func cancelListenerRebuild() {
    listenerRestartTimer?.cancel()
    listenerRestartTimer = nil
    controlListenerGeneration += 1
  }

  /// Waits on a one-shot timer, then builds a replacement listener.
  private func scheduleRebuild(afterMilliseconds: Int, generation: Int) {
    listenerRestartTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(deadline: .now() + .milliseconds(afterMilliseconds))
    timer.setEventHandler { @Sendable [weak self] in
      Task { await self?.rebuildControlListener(generation: generation) }
    }
    timer.resume()
    listenerRestartTimer = timer
  }

  /// Builds a replacement listener, reporting a failure that leaves none.
  ///
  /// A rebuild that throws does not schedule another one itself. Either the listener
  /// binds and fails again, which reports through the serving handler and continues
  /// the run, or nothing was built and the next client request tries again.
  private func rebuildControlListener(generation: Int) async {
    guard generation == controlListenerGeneration else {
      return
    }
    listenerRestartTimer = nil
    isRebuildingControlListener = true
    do {
      try await ensureControlListenerStarted()
    } catch {
      logger.error(
        """
        agent control listener rebuild failed \
        details=\(String(describing: error), privacy: .public) \
        recovery=celltunnelctl-start-discovery
        """
      )
    }
    isRebuildingControlListener = false
  }
}

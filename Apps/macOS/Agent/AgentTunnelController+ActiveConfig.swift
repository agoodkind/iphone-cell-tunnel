//
//  AgentTunnelController+ActiveConfig.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-01.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
@preconcurrency import NetworkExtension

private let logger = CellTunnelLog.logger(category: .daemon)

/// How many times the tunnel is asked to follow before the attempt is reported instead of
/// repeated. Each pass restarts because another request changed the active entry, so a run
/// this long means requests are arriving faster than the tunnel can follow them, and
/// looping further would keep a caller waiting with no end.
private let maximumActiveConfigFollowPasses = 4

// MARK: - Following the active config

extension AgentTunnelController {
  /// Makes a running tunnel carry the configuration that is now active.
  ///
  /// Choosing a configuration does not by itself change what the tunnel carries. The
  /// extension keeps serving the text it was started with, so a person who starts,
  /// activates, or imports while the tunnel runs gets a library that reports one
  /// configuration and a tunnel that carries another, with nothing on any surface
  /// showing the disagreement.
  ///
  /// The comparison is the same one the launch assertion makes, so a tunnel that already
  /// carries the active entry is left alone rather than reloaded for nothing. A tunnel
  /// carrying no id cannot be shown to agree, so it follows too.
  ///
  /// Nothing runs when the tunnel is stopped, so this does nothing then, and activating a
  /// configuration still starts no tunnel.
  ///
  /// Returns a failure to hand back when the tunnel had to follow and could not, so the
  /// caller reports what happened instead of returning a status that implies the named
  /// configuration is in force. Returns `nil` when the tunnel carries the active entry.
  func followActiveConfigOnRunningTunnel() async -> AgentControlResponse? {
    // This actor is re-entrant, so another request can make a different entry active
    // while this one is suspended loading the manager or reloading. Each pass re-reads
    // the active entry after every suspension and starts over when it changed, so the
    // tunnel and the profile end on the entry the library actually holds rather than on
    // whichever request happened to resume last.
    for _ in 0..<maximumActiveConfigFollowPasses {
      guard let activeID = configStore.activeID, let text = configStore.text(forID: activeID)
      else {
        return nil
      }
      let manager: NETunnelProviderManager
      do {
        manager = try await loadOrCreateManager()
      } catch {
        logger.error(
          """
          agent active config follow could not load the manager \
          details=\(String(describing: error), privacy: .public) recovery=return-failure
          """
        )
        return failure(from: error)
      }
      guard configStore.activeID == activeID else {
        continue
      }
      guard isSessionActive(on: manager) else {
        return nil
      }
      guard runningTunnelNeedsActiveConfig(on: manager, activeID: activeID) else {
        return nil
      }
      if let followFailure = await restartRunningTunnel(
        text: text, configID: activeID, on: manager)
      {
        return followFailure
      }
      guard configStore.activeID == activeID else {
        continue
      }
      return nil
    }
    logger.error(
      """
      agent active config follow gave up while the active entry kept changing \
      recovery=await-next-request
      """
    )
    return failure(
      errorCode: .internal,
      message: "the active configuration kept changing; the tunnel may not carry it yet"
    )
  }

  /// Makes a running tunnel carry edited text for the configuration it is already on.
  ///
  /// Editing the active entry keeps its id, so the follow path sees the tunnel and the
  /// library agreeing and correctly does nothing. The text still changed, and the name
  /// servers it names are applied only when a session starts, so the same restart the
  /// swap uses is what makes an edited resolver line take effect.
  ///
  /// Nothing runs when the tunnel is stopped, and nothing runs when the edited entry is
  /// not the one in force.
  func reapplyEditedConfigToRunningTunnel(
    text: String,
    configID: UUID
  ) async -> AgentControlResponse? {
    let manager: NETunnelProviderManager
    do {
      manager = try await loadOrCreateManager()
    } catch {
      logger.error(
        """
        agent edited config reapply could not load the manager \
        details=\(String(describing: error), privacy: .public) recovery=return-failure
        """
      )
      return failure(from: error)
    }
    guard isSessionActive(on: manager) else {
      return nil
    }
    return await restartRunningTunnel(text: text, configID: configID, on: manager)
  }

  /// Makes the entry that was active before this request active again, after the tunnel
  /// could not be made to follow the new one.
  ///
  /// Leaving the new entry selected would tell a person their choice took effect on a
  /// request that just reported failure, and the library would name a configuration the
  /// tunnel is not carrying, which is the disagreement this whole path exists to prevent.
  ///
  /// Only the selection is restored. A row that was added is kept, because deduplication
  /// returns an entry that already existed whenever the text matches, so deleting it could
  /// remove a configuration the person stored earlier.
  func restoreActiveConfig(to previousID: UUID?) {
    guard let previousID, configStore.text(forID: previousID) != nil else {
      return
    }
    configStore.setActive(id: previousID)
  }

  /// Whether the running tunnel carries something other than the active entry.
  ///
  /// This reads the id the tunnel was stamped with and applies the same rule the launch
  /// assertion uses, so one definition of agreement covers both.
  private func runningTunnelNeedsActiveConfig(
    on manager: NETunnelProviderManager,
    activeID: UUID
  ) -> Bool {
    guard
      let providerProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol,
      let providerConfiguration = providerProtocol.providerConfiguration
    else {
      return true
    }
    let runningRaw = providerConfiguration[Self.providerConfigConfigIDKey] as? String
    let runningID = runningRaw.flatMap(UUID.init(uuidString:))
    let libraryIDs = Set(configStore.list().map(\.id))
    let drift = evaluateConfigLibraryDrift(
      runningConfigID: runningID,
      activeID: activeID,
      libraryIDs: libraryIDs
    )
    return drift != .ok
  }

  /// Swaps the running tunnel onto this configuration by restarting its session.
  ///
  /// The session restarts rather than reloading in place because the name servers a
  /// tunnel publishes are applied when a session starts and at no other time. Changing
  /// the configuration underneath a live session moved the routes and the server endpoint
  /// but left name resolution answering from the configuration the session began with,
  /// in both directions: a configuration naming servers never published them, and one
  /// naming none never withdrew the ones already published. Re-applying the settings a
  /// second time was tried and does not make them take, so the session is what changes.
  ///
  /// Traffic stops for the length of the restart. Nothing has to announce that
  /// separately: the routes go down with the session, so the published routing phase
  /// reads connecting until they land again, which is what every client already renders
  /// while a tunnel is coming up.
  ///
  /// The profile is stamped before the restart, because the extension reads its
  /// configuration from the saved profile when a session starts. Stamping afterwards, as
  /// the in-place reload did, would start the new session on the previous configuration.
  private func restartRunningTunnel(
    text: String,
    configID: UUID,
    on manager: NETunnelProviderManager
  ) async -> AgentControlResponse? {
    applyConfiguration(to: manager, wireGuardConfig: text, configID: configID)
    do {
      try await save(manager: manager)
      try await load(manager: manager)
    } catch {
      logger.error(
        """
        agent active config follow could not stamp the profile \
        details=\(String(describing: error), privacy: .public) recovery=return-failure
        """
      )
      return failure(from: error)
    }

    logger.notice(
      """
      agent restarting the tunnel session to apply the active config \
      id=\(configID.uuidString, privacy: .public) reason=resolvers-follow-the-session
      """
    )
    switch await cycleSession(on: manager) {
    case .failed(let response):
      return response
    case .superseded:
      // Another request tore the tunnel down while this one was cycling, so this
      // configuration is not in force and saying it is would be false. The request that
      // superseded it is the one that decides what happens next.
      return nil
    case .applied:
      logger.notice(
        """
        agent running tunnel now carries the active config \
        id=\(configID.uuidString, privacy: .public)
        """
      )
      return nil
    }
  }

  /// Stops the session, waits for it to go down, starts it again, and waits for it to
  /// come back, refusing to claim success for any step that did not happen.
  ///
  /// The whole sequence suspends for as long as a stop and a start take, which is long
  /// enough for the routing switch to be turned off underneath it. That off request
  /// tears everything down, so starting a session afterwards would raise a tunnel nobody
  /// asked for. The routing generation is what tells a superseded restart to stop, and a
  /// superseded restart is not a failure: it is someone else's request winning.
  private func cycleSession(
    on manager: NETunnelProviderManager
  ) async -> SessionCycleOutcome {
    let generation = routingGeneration
    stopSession(on: manager)
    guard await waitForSessionDisconnected(on: manager) else {
      logger.error(
        """
        agent active config follow gave up waiting for the session to go down \
        recovery=return-failure
        """
      )
      return .failed(
        failure(
          errorCode: .internal,
          message: "the tunnel did not stop, so the configuration was not applied"
        )
      )
    }
    guard routingGeneration == generation else {
      logger.notice("agent active config restart superseded recovery=leave-tunnel-stopped")
      return .superseded
    }
    do {
      try startSession(on: manager)
    } catch {
      logger.error(
        """
        agent active config follow could not restart the session \
        details=\(String(describing: error), privacy: .public) recovery=return-failure
        """
      )
      return .failed(failure(from: error))
    }
    let connected = await waitForSessionConnected(on: manager)
    // Checked before the connect result, because a stop arriving during the wait is why
    // the session is not connected, and reporting a failure for what someone asked for
    // would be wrong.
    guard routingGeneration == generation else {
      logger.notice("agent active config restart superseded recovery=leave-tunnel-stopped")
      return .superseded
    }
    guard connected else {
      logger.error(
        """
        agent active config follow restarted the session but it never connected \
        recovery=return-failure
        """
      )
      return .failed(
        failure(
          errorCode: .internal,
          message: "the tunnel did not come back up, so the configuration is not in force"
        )
      )
    }
    // The restart replaced the extension process, and the new one starts with its routes
    // withdrawn. The phone link never dropped, so nothing else re-asserts them and the
    // tunnel would sit connecting with a live peer and no traffic. Measured: two minutes
    // after a swap, routes stayed not-installed with the peer present.
    await signalRouteState(phoneLinkUp)
    return .applied
  }
}

// MARK: - SessionCycleOutcome

/// What a stop-and-start of the tunnel session ended up doing.
///
/// Superseded is kept apart from applied because both leave nothing for the caller to
/// report, and collapsing them would have the caller announce that a configuration is in
/// force on a tunnel another request just stopped.
private enum SessionCycleOutcome {
  case applied
  case failed(AgentControlResponse)
  case superseded
}

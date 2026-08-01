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
    guard isSessionActive(on: manager) else {
      return nil
    }
    guard runningTunnelNeedsActiveConfig(on: manager, activeID: activeID) else {
      return nil
    }
    return await reloadRunningTunnel(text: text, configID: activeID, on: manager)
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

  /// Swaps the running tunnel onto this configuration and re-stamps the saved profile.
  ///
  /// The swap happens in the extension, which changes routes and resolvers without
  /// restarting the session, so the relay keeps carrying datagrams across the change.
  ///
  /// The saved profile is stamped afterwards because it is what a later launch reads. A
  /// profile left holding the previous id would make the launch assertion report drift on
  /// a tunnel that is in fact carrying the right configuration.
  private func reloadRunningTunnel(
    text: String,
    configID: UUID,
    on manager: NETunnelProviderManager
  ) async -> AgentControlResponse? {
    let path: String
    do {
      path = try writeTempConfig(text)
    } catch {
      logger.error(
        """
        agent active config follow could not stage the config \
        details=\(String(describing: error), privacy: .public) recovery=return-failure
        """
      )
      return failure(from: error)
    }
    defer { removeTempConfig(at: path) }
    let response = await handleReloadTunnel(
      settings: TunnelStartSettings(wireGuardConfigPath: path)
    )
    if let reloadFailure = response.failure {
      logger.error(
        """
        agent active config follow reload failed \
        details=\(String(describing: reloadFailure), privacy: .public) recovery=return-failure
        """
      )
      return response
    }
    await stampProfile(text: text, configID: configID, on: manager)
    logger.notice(
      "agent running tunnel now carries the active config id=\(configID.uuidString, privacy: .public)"
    )
    return nil
  }

  /// Records this configuration on the saved profile so a later launch reads it.
  ///
  /// A failure here leaves the running tunnel correct and only the saved profile stale,
  /// which the launch assertion reports rather than acts on, so it is logged instead of
  /// failing the request that a person just watched succeed.
  private func stampProfile(
    text: String,
    configID: UUID,
    on manager: NETunnelProviderManager
  ) async {
    applyConfiguration(to: manager, wireGuardConfig: text, configID: configID)
    do {
      try await save(manager: manager)
    } catch {
      logger.error(
        """
        agent active config stamp failed \
        details=\(String(describing: error), privacy: .public) recovery=leave-profile-stale
        """
      )
    }
  }
}

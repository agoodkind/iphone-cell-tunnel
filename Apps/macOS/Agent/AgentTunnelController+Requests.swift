//
//  AgentTunnelController+Requests.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-24.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
@preconcurrency import NetworkExtension

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .daemon)

// MARK: - Request handling

extension AgentTunnelController {
  func handle(request: AgentControlRequest) async -> AgentControlResponse {
    switch request {
    case .activateConfig(let id):
      return await handleActivateConfig(id: id)
    case .check:
      return await handleCheck()
    case .deleteConfig(let id):
      return await handleDeleteConfig(id: id)
    case .getConfigText(let id):
      return handleGetConfigText(id: id)
    case let .importConfig(name, text):
      return await handleImportConfig(name: name, text: text)
    case .listRelayServices:
      return snapshotResponse()
    case .reloadTunnel(let settings):
      return await handleReloadTunnel(settings: settings)
    case let .renameConfig(id, name):
      return await handleRenameConfig(id: id, name: name)
    case .reset:
      return await handleReset()
    case let .saveConfigEdit(id, text):
      return await handleSaveConfigEdit(id: id, text: text)
    case .selectEgressPeer(let peerID):
      return await handleSelectEgressPeer(peerID: peerID)
    case .selectRelayService(let serviceID):
      return selectRelay(serviceID: serviceID)
    case .setActiveConfig(let id):
      return await handleSetActiveConfig(id: id)
    case .setRoutingEnabled(let enabled):
      return await handleSetRoutingEnabled(enabled)
    case .startPairing:
      return await handleStartPairing()
    case .startRelay:
      return await handleStartRelay()
    case .startRelayDiscovery:
      return startDiscovery()
    case .startTunnel(let settings):
      return await handleStartTunnel(settings: settings)
    case .status:
      return await handleStatus()
    case .stopRelayDiscovery:
      return snapshotResponse()
    case .stopTunnel:
      return await handleSetRoutingEnabled(false)
    case .validateConfig(let text):
      return await handleValidateConfig(text: text)
    }
  }

  /// Selects which connected iPhone the agent routes egress through, then returns the
  /// refreshed status so the Mac sees the new selection reflected in the roster.
  private func handleSelectEgressPeer(peerID: String) async -> AgentControlResponse {
    await controlListener?.selectPeer(peerID: peerID)
    return await handleStatus()
  }

  /// Drives the relay session from the Route traffic switch. Turning routing on
  /// validates the same preconditions `handleStartRelay` checks and returns the
  /// matching error without starting anything when one is missing, then starts the
  /// session detached so the reply does not block on the connect. Turning it off
  /// withdraws routes and stops the session. The status snapshot returns immediately so
  /// the app's polls animate the transition.
  private func handleSetRoutingEnabled(_ enabled: Bool) async -> AgentControlResponse {
    if enabled {
      guard let activeID = configStore.activeID,
        configStore.text(forID: activeID) != nil
      else {
        return failure(
          errorCode: .configSelectionRequired,
          message: "no active config selected"
        )
      }
      if await controlListener?.hasSelectedPeer() != true {
        return failure(
          errorCode: .relaySelectionRequired,
          message: "no selected peer connection"
        )
      }
    }
    await setRoutingEnabled(enabled)
    return await handleStatus()
  }

  func handleStatus() async -> AgentControlResponse {
    do {
      let loadedManager = try await loadOrCreateManager()
      guard isSessionActive(on: loadedManager) else {
        return AgentControlResponse(status: augmented(snapshot(from: loadedManager)))
      }
      return try await forwardStatus(on: loadedManager)
    } catch {
      logger.error(
        """
        status agent operation caught error \
        details=\(String(describing: error), privacy: .public) \
        recovery=return-failure-response
        """
      )
      return failure(from: error)
    }
  }

  private func handleCheck() async -> AgentControlResponse {
    var checks = [
      TunnelEnvironmentCheckResult(name: "provider_bundle", value: Self.providerBundleIdentifier)
    ]
    checks.append(
      TunnelEnvironmentCheckResult(
        name: "agent_executable_path", value: AgentBinaryIdentity.executablePath()))
    if let buildUUID = AgentBinaryIdentity.buildUUID() {
      checks.append(
        TunnelEnvironmentCheckResult(name: "agent_build_uuid", value: buildUUID))
    }
    if let executableSHA256 = AgentBinaryIdentity.sha256() {
      checks.append(
        TunnelEnvironmentCheckResult(
          name: "agent_executable_sha256", value: executableSHA256))
    }
    do {
      let loadedManager = try await loadOrCreateManager()
      checks.append(
        TunnelEnvironmentCheckResult(
          name: "configuration_present",
          value: String(loadedManager.protocolConfiguration != nil)
        )
      )
      checks.append(
        TunnelEnvironmentCheckResult(
          name: "vpn_status",
          value: statusDescription(loadedManager.connection.status)
        )
      )
    } catch {
      logger.error(
        """
        check agent operation caught error \
        details=\(String(describing: error), privacy: .public) \
        recovery=append-configuration-error
        """
      )
      checks.append(
        TunnelEnvironmentCheckResult(
          name: "configuration_error",
          value: error.localizedDescription
        )
      )
    }
    return AgentControlResponse(report: TunnelEnvironmentReport(checks: checks))
  }

  private func handleStartPairing() async -> AgentControlResponse {
    do {
      try await ensureControlListenerStarted()
      return await handleStatus()
    } catch {
      logger.error(
        """
        startPairing agent operation caught error \
        details=\(String(describing: error), privacy: .public) \
        recovery=return-failure-response
        """
      )
      return failure(from: error)
    }
  }

  /// The Start Relay control is an alias for turning routing on. It routes through the
  /// single routing-enable path so the relay-hosted and routing-on states never diverge,
  /// whichever entry point starts the relay.
  private func handleStartRelay() async -> AgentControlResponse {
    await handleSetRoutingEnabled(true)
  }

  func handleStartTunnel(settings: TunnelStartSettings) async -> AgentControlResponse {
    guard settings.hasWireGuardConfigPath else {
      return failure(
        errorCode: .missingWireGuardConfigPath,
        message: "start requires a WireGuard config path"
      )
    }
    let saved: StoredTunnelConfig
    do {
      let configText = try readConfigText(at: settings.wireGuardConfigPath)
      saved = try configStore.addDeduplicated(
        name: Self.configName(fromPath: settings.wireGuardConfigPath),
        text: configText
      )
      configStore.setActive(id: saved.id)
    } catch {
      logger.error(
        """
        startTunnel config resolve failed \
        details=\(String(describing: error), privacy: .public) \
        recovery=return-failure-response
        """
      )
      return failure(from: error)
    }
    // The config is now active, so start through the routing-enable path to keep the
    // relay-hosted and routing states consistent across every start entry point.
    return await handleSetRoutingEnabled(true)
  }

  /// Starts the tunnel for an already-resolved library entry, stamping the saved
  /// profile with the library id so the profile is a downstream projection of the
  /// active entry. Activation and import call this directly with the known id.
  func startTunnel(configText: String, configID: UUID) async -> AgentControlResponse {
    do {
      try await ensureControlListenerStarted()
      if await controlListener?.hasSelectedPeer() != true {
        return failure(
          errorCode: .relaySelectionRequired,
          message: "no selected peer connection"
        )
      }
      let loadedManager = try await loadOrCreateManager()
      applyConfiguration(to: loadedManager, wireGuardConfig: configText, configID: configID)
      try await save(manager: loadedManager)
      try await load(manager: loadedManager)
      try await startRelay(wireGuardConfig: configText)
      observeStatus(on: loadedManager)
      try startSession(on: loadedManager)
      logger.notice(
        "agent tunnel start requested configID=\(configID.uuidString, privacy: .public)")
      await waitForSessionConnected(on: loadedManager)
      configDriftMessage = nil
      return try await forwardStatus(on: loadedManager)
    } catch {
      logger.error(
        """
        startTunnel agent operation caught error \
        details=\(String(describing: error), privacy: .public) \
        recovery=return-failure-response
        """
      )
      return failure(from: error)
    }
  }

  func handleStopTunnel() async -> AgentControlResponse {
    do {
      let loadedManager = try await loadOrCreateManager()
      stopSession(on: loadedManager)
      await stopRelay()
      logger.notice("agent tunnel stop requested")
      return AgentControlResponse(status: augmented(snapshot(from: loadedManager)))
    } catch {
      logger.error(
        """
        stopTunnel agent operation caught error \
        details=\(String(describing: error), privacy: .public) \
        recovery=return-failure-response
        """
      )
      return failure(from: error)
    }
  }

  private func handleReset() async -> AgentControlResponse {
    // Supersede any in-flight detached start at reset entry so it cannot complete and
    // re-host the relay after the reset tears everything down.
    routingGeneration += 1
    do {
      let managers = try await loadAllManagers()
      for candidate in managers {
        stopSession(on: candidate)
        try await remove(manager: candidate)
      }
      await stopControlListener()
      clearManager()
      routingEnabled = false
      lastStartError = nil
      EgressSelectionStore.clear()
      clearConfigLibrary()
      replaceStatusObserver(nil)
      logger.notice(
        "agent tunnel reset removed managerCount=\(managers.count, privacy: .public)"
      )
      return AgentControlResponse(
        status: TunnelDaemonStatusSnapshot(
          running: false,
          routeState: .notInstalled,
          peerState: .notSelected,
          configLibrary: configStore.summaries(),
          activeConfigID: configStore.activeID
        )
      )
    } catch {
      logger.error(
        """
        reset agent operation caught error \
        details=\(String(describing: error), privacy: .public) \
        recovery=return-failure-response
        """
      )
      return failure(from: error)
    }
  }

  func forwardStatus(
    on manager: NETunnelProviderManager
  ) async throws -> AgentControlResponse {
    let response = try await forward(request: .status, on: manager, operationName: "status")
    if let status = response.status {
      return AgentControlResponse(status: augmented(status))
    }
    return AgentControlResponse(status: augmented(snapshot(from: manager)))
  }
}

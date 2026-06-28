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
      return await handleStopTunnel()
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

  private func handleSetRoutingEnabled(_ enabled: Bool) async -> AgentControlResponse {
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

  private func handleStartRelay() async -> AgentControlResponse {
    guard let activeID = configStore.activeID,
      let configText = configStore.text(forID: activeID)
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
    return await startTunnel(configText: configText, configID: activeID)
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
    return await startTunnel(configText: saved.text, configID: saved.id)
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
    do {
      let managers = try await loadAllManagers()
      for candidate in managers {
        stopSession(on: candidate)
        try await remove(manager: candidate)
      }
      await stopControlListener()
      clearManager()
      RoutingIntentStore.clear()
      routingEnabled = RoutingIntentStore.load()
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

// MARK: - Tunnel manager helpers

extension AgentTunnelController {
  func loadOrCreateManager() async throws -> NETunnelProviderManager {
    if let manager = currentManager() {
      return manager
    }
    let managers = try await loadAllManagers()
    let resolved = managers.first ?? NETunnelProviderManager()
    setManager(resolved)
    logger.notice("agent resolved tunnel manager count=\(managers.count, privacy: .public)")
    return resolved
  }

  /// Writes the active config into the saved profile and stamps it with the library
  /// id (as `uuidString`), so the profile is a downstream projection of the active
  /// library entry that boot can verify by id.
  private func applyConfiguration(
    to manager: NETunnelProviderManager,
    wireGuardConfig: String,
    configID: UUID
  ) {
    let providerProtocol = NETunnelProviderProtocol()
    providerProtocol.providerBundleIdentifier = Self.providerBundleIdentifier
    providerProtocol.serverAddress = Self.tunnelServerAddressPlaceholder
    var providerConfiguration = [
      Self.providerConfigWireGuardKey: wireGuardConfig,
      Self.providerConfigConfigIDKey: configID.uuidString,
    ]
    if let relayName = resolvedRelayServiceName() {
      providerConfiguration[Self.providerConfigRelayServiceKey] = relayName
    }
    providerProtocol.providerConfiguration = providerConfiguration
    manager.protocolConfiguration = providerProtocol
    manager.localizedDescription = Self.tunnelLocalizedDescription
    manager.isEnabled = true
  }

  private func save(manager: NETunnelProviderManager) async throws {
    try await resumeVoidContinuation { completion in
      manager.saveToPreferences(completionHandler: completion)
    }
  }

  private func load(manager: NETunnelProviderManager) async throws {
    try await resumeVoidContinuation { completion in
      manager.loadFromPreferences(completionHandler: completion)
    }
  }

  private func remove(manager: NETunnelProviderManager) async throws {
    try await resumeVoidContinuation { completion in
      manager.removeFromPreferences(completionHandler: completion)
    }
  }

  private func startSession(on manager: NETunnelProviderManager) throws {
    guard let session = manager.connection as? NETunnelProviderSession else {
      throw AgentTunnelControllerError.sessionUnavailable
    }
    try session.startTunnel(options: nil)
  }

  private func stopSession(on manager: NETunnelProviderManager) {
    guard let session = manager.connection as? NETunnelProviderSession else {
      return
    }
    session.stopTunnel()
  }

  func isSessionActive(on manager: NETunnelProviderManager) -> Bool {
    switch manager.connection.status {
    case .connected, .connecting, .reasserting:
      return true
    default:
      return false
    }
  }

  private func observeStatus(on manager: NETunnelProviderManager) {
    let connection = manager.connection
    replaceStatusObserver(
      NotificationCenter.default.addObserver(
        forName: .NEVPNStatusDidChange,
        object: connection,
        queue: nil
      ) { [weak self] _ in
        let observed = connection.status
        Task { await self?.recordStatus(observed) }
      }
    )
  }

  private func recordStatus(_ status: NEVPNStatus) {
    logger.notice(
      "agent observed vpn status=\(self.statusDescription(status), privacy: .public)"
    )
  }

  func signalRouteState(_ installed: Bool) async {
    guard let manager = currentManager() else {
      await controlListener?.sendRouteState(installed)
      return
    }
    do {
      _ = try await forward(
        request: .setRouteState(installed: installed),
        on: manager,
        operationName: "setRouteState"
      )
      logger.notice(
        "agent signaled route state installed=\(installed, privacy: .public)"
      )
      await controlListener?.sendRouteState(installed)
      await refreshDeviceAddress()
    } catch {
      logger.error(
        """
        agent route state signal failed installed=\(installed, privacy: .public) \
        details=\(String(describing: error), privacy: .public) recovery=await-next-link-change
        """
      )
    }
  }

  func forward(
    request: ProviderControlRequest,
    on manager: NETunnelProviderManager,
    operationName: String
  ) async throws -> ProviderControlResponse {
    guard let session = manager.connection as? NETunnelProviderSession else {
      throw AgentTunnelControllerError.sessionUnavailable
    }
    let payload = try JSONEncoder().encode(ProviderControlEnvelope(request: request))
    let responseData = try await sendProviderMessage(
      payload,
      on: session,
      operationName: operationName
    )
    return try JSONDecoder().decode(ProviderControlResponse.self, from: responseData)
  }

  private func sendProviderMessage(
    _ payload: Data,
    on session: NETunnelProviderSession,
    operationName: String
  ) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      let box = ProviderMessageContinuationBox(
        continuation: continuation,
        operationName: operationName
      )
      do {
        try session.sendProviderMessage(payload) { response in
          box.resume(with: response)
        }
      } catch {
        logger.error(
          """
          \(operationName) provider message send failed \
          details=\(String(describing: error), privacy: .public) \
          recovery=resume-continuation-with-error
          """
        )
        box.resumeOnce(throwing: error)
      }
      box.scheduleTimeout(Self.providerMessageTimeoutSeconds)
    }
  }

  private func snapshot(from manager: NETunnelProviderManager) -> TunnelDaemonStatusSnapshot {
    let status = manager.connection.status
    let configured = manager.protocolConfiguration != nil
    let configurationUnapproved = status == .invalid && configured
    return TunnelDaemonStatusSnapshot(
      running: isSessionActive(on: manager),
      peerState: configured ? .wireGuardConfigured : .notSelected,
      lastError: configurationUnapproved ? "vpn configuration not approved" : nil
    )
  }
}

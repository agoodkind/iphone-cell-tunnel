//
//  AgentTunnelController.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-27.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
@preconcurrency import NetworkExtension
import Synchronization
import WireGuardKit

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .daemon)

private let providerBundleIdentifier = tunnelProviderBundleIdentifier
private let providerConfigWireGuardKey = "wireguardConfig"
private let providerConfigRelayServiceKey = "selectedRelayServiceName"
private let tunnelLocalizedDescription = "Cell Tunnel"
private let tunnelServerAddressPlaceholder = "iPhone Cellular Relay"
private let providerMessageTimeoutSeconds: Double = 5

// MARK: - AgentTunnelController

actor AgentTunnelController {
  private var manager: NETunnelProviderManager?
  private var statusObserver: NSObjectProtocol?
  var controlListener: AgentControlListener?
  let relayBridge: AgentRelayBridge
  let relayBrowser: RelayDeviceBrowser

  /// The carrying link info, written from the bridge's egress callback off-actor and
  /// read into the served snapshot. Nonisolated because the `Mutex` is its own
  /// synchronization and the bridge callback runs off the actor.
  nonisolated let linkInfo = Mutex(AgentLinkInfo())
  /// The connected iPhone's name, written from the listener's status handler off
  /// the actor and read into the served snapshot as `connectedPeerName`. Cleared
  /// when the phone link drops.
  nonisolated let peerName = Mutex<String?>(nil)
  /// The Mac's latest egress reading, written from the egress monitor off the actor
  /// and mapped into the served snapshot's `cellularPath`, so the Mac `Device`
  /// section reports the Mac's own egress.
  nonisolated let egressPath = Mutex(EgressPath())
  /// The public-address exchange with the iPhone, read into the served snapshot.
  var publicExchange: PublicAddressExchange?
  /// Watches the Mac's own egress path so a Wi-Fi or interface change re-probes the
  /// public address.
  var egressMonitor: EgressPathMonitor?
  /// Re-probes the public address on a slow backstop while the listener is up, so a
  /// missed path event cannot leave the served address stale.
  var publicRefreshTimer: DispatchSourceTimer?

  init(relayBridge: AgentRelayBridge, relayBrowser: RelayDeviceBrowser) {
    self.relayBridge = relayBridge
    self.relayBrowser = relayBrowser
  }

  /// Whether the user has turned routing on. The agent installs the program
  /// routes only while this is true and a phone link is up, so the default is
  /// passthrough: the link stays up carrying nothing until routing is enabled.
  var routingEnabled = false

  /// Whether a phone relay link is up, tracked from the relay bridge so a routing
  /// change installs or withdraws routes against the live link state.
  var phoneLinkUp = false

  /// Called when the relay goes active or inactive so the runtime can hold the
  /// agent idle timer while it hosts the relay bridge. Set once at startup.
  var onRelayActiveChange: (@Sendable (Bool) -> Void)?

  // MARK: - Relay activity hold

  func setRelayActiveHandler(_ handler: @escaping @Sendable (Bool) -> Void) {
    onRelayActiveChange = handler
  }

  // MARK: - Request handling

  func handle(request: AgentControlRequest) async -> AgentControlResponse {
    switch request {
    case .status:
      return await handleStatus()
    case .check:
      return await handleCheck()
    case .startTunnel(let settings):
      return await handleStartTunnel(settings: settings)
    case .reloadTunnel(let settings):
      return await handleReloadTunnel(settings: settings)
    case .stopTunnel:
      return await handleStopTunnel()
    case .reset:
      return await handleReset()
    case .startRelayDiscovery:
      return startDiscovery()
    case .stopRelayDiscovery:
      return snapshotResponse()
    case .listRelayServices:
      return snapshotResponse()
    case .selectRelayService(let serviceID):
      return selectRelay(serviceID: serviceID)
    case .setRoutingEnabled(let enabled):
      return await handleSetRoutingEnabled(enabled)
    }
  }

  private func handleSetRoutingEnabled(_ enabled: Bool) async -> AgentControlResponse {
    await setRoutingEnabled(enabled)
    return await handleStatus()
  }

  private func handleStatus() async -> AgentControlResponse {
    do {
      let loadedManager = try await loadOrCreateManager()
      guard isSessionActive(on: loadedManager) else {
        return AgentControlResponse(status: snapshot(from: loadedManager))
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
      TunnelEnvironmentCheckResult(name: "provider_bundle", value: providerBundleIdentifier)
    ]
    // Report the running binary's identity so a reinstall can confirm the agent
    // came up and is the freshly built one, not a stale agent at another path.
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

  private func handleStartTunnel(settings: TunnelStartSettings) async -> AgentControlResponse {
    guard settings.hasWireGuardConfigPath else {
      return failure(
        errorCode: .missingWireGuardConfigPath,
        message: "start requires a WireGuard config path"
      )
    }
    do {
      let configText = try readConfigText(at: settings.wireGuardConfigPath)
      let loadedManager = try await loadOrCreateManager()
      applyConfiguration(to: loadedManager, wireGuardConfig: configText)
      try await save(manager: loadedManager)
      try await load(manager: loadedManager)
      try await startControlListener(wireGuardConfig: configText)
      observeStatus(on: loadedManager)
      try startSession(on: loadedManager)
      logger.notice("agent tunnel start requested")
      await waitForSessionConnected(on: loadedManager)
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

  private func handleStopTunnel() async -> AgentControlResponse {
    do {
      let loadedManager = try await loadOrCreateManager()
      stopSession(on: loadedManager)
      await stopControlListener()
      logger.notice("agent tunnel stop requested")
      return AgentControlResponse(status: snapshot(from: loadedManager))
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
      manager = nil
      if let statusObserver {
        NotificationCenter.default.removeObserver(statusObserver)
        self.statusObserver = nil
      }
      logger.notice(
        "agent tunnel reset removed managerCount=\(managers.count, privacy: .public)"
      )
      return AgentControlResponse(
        status: TunnelDaemonStatusSnapshot(
          running: false,
          routeState: .notInstalled,
          peerState: .notSelected
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

  private func startDiscovery() -> AgentControlResponse {
    relayBrowser.start()
    logger.notice("agent relay discovery started from browser")
    return snapshotResponse()
  }

  private func selectRelay(serviceID: String) -> AgentControlResponse {
    let devices = relayBrowser.snapshot()
    guard let device = devices.first(where: { $0.identifier == serviceID }) else {
      return failure(
        errorCode: .relaySelectionRequired,
        message: "no discovered relay with id \(serviceID)"
      )
    }
    RelaySelectionStore.setSelectedRelayServiceName(device.serviceName)
    logger.notice(
      "agent selected relay service=\(device.serviceName, privacy: .public)"
    )
    return snapshotResponse()
  }

  private func snapshotResponse() -> AgentControlResponse {
    let devices = relayBrowser.snapshot()
    let selectedServiceName = RelaySelectionStore.selectedRelayServiceName()
    let services = devices.map { device in
      TunnelRelayService(
        id: device.identifier,
        serviceName: device.serviceName,
        serviceType: device.serviceType,
        domain: device.domain,
        interfaceIndex: device.interfaceIndex,
        hostName: "",
        endpoints: [],
        preferredEndpoint: nil,
        isSelected: device.serviceName == selectedServiceName
      )
    }
    let selectedServiceID = devices.first { device in
      device.serviceName == selectedServiceName
    }?.identifier
    let snapshot = TunnelDiscoverySnapshot(
      phase: services.isEmpty ? .browsing : .ready,
      services: services,
      selectedServiceID: selectedServiceID
    )
    return AgentControlResponse(discovery: snapshot)
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

// MARK: - AgentTunnelController

extension AgentTunnelController {
  func loadOrCreateManager() async throws -> NETunnelProviderManager {
    if let manager {
      return manager
    }
    let managers = try await loadAllManagers()
    let resolved = managers.first ?? NETunnelProviderManager()
    manager = resolved
    logger.notice("agent resolved tunnel manager count=\(managers.count, privacy: .public)")
    return resolved
  }

  private func applyConfiguration(
    to manager: NETunnelProviderManager,
    wireGuardConfig: String
  ) {
    let providerProtocol = NETunnelProviderProtocol()
    providerProtocol.providerBundleIdentifier = providerBundleIdentifier
    providerProtocol.serverAddress = tunnelServerAddressPlaceholder
    var providerConfiguration = [providerConfigWireGuardKey: wireGuardConfig]
    if let relayName = resolvedRelayServiceName() {
      providerConfiguration[providerConfigRelayServiceKey] = relayName
    }
    providerProtocol.providerConfiguration = providerConfiguration
    manager.protocolConfiguration = providerProtocol
    manager.localizedDescription = tunnelLocalizedDescription
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
    if let statusObserver {
      NotificationCenter.default.removeObserver(statusObserver)
    }
    let connection = manager.connection
    statusObserver = NotificationCenter.default.addObserver(
      forName: .NEVPNStatusDidChange,
      object: connection,
      queue: nil
    ) { [weak self] _ in
      let observed = connection.status
      Task { await self?.recordStatus(observed) }
    }
  }

  private func recordStatus(_ status: NEVPNStatus) {
    logger.notice(
      "agent observed vpn status=\(self.statusDescription(status), privacy: .public)"
    )
  }

  // Tells the Mac extension to install or withdraw routes as the iPhone relay
  // link comes and goes, so routes track the link rather than tunnel start.
  func signalRouteState(_ installed: Bool) async {
    guard let manager else {
      // No Mac tunnel means no routes exist; tell the iPhone the truth anyway.
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
      // The extension applied the route change, so report the confirmed state
      // to the iPhone over the control link.
      await controlListener?.sendRouteState(installed)
      // Routing on or off changes which egress the Mac's own traffic takes, so
      // its public address can change; re-probe and re-send it.
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
      box.scheduleTimeout(providerMessageTimeoutSeconds)
    }
  }

  private func snapshot(from manager: NETunnelProviderManager) -> TunnelDaemonStatusSnapshot {
    let status = manager.connection.status
    let configured = manager.protocolConfiguration != nil
    // The invalid status reports a real failure only when a configuration exists
    // but the system has not approved it. With no configuration saved the tunnel is
    // simply not installed, so reporting an error would mask the not-installed state
    // and its setup screen.
    let configurationUnapproved = status == .invalid && configured
    return TunnelDaemonStatusSnapshot(
      running: isSessionActive(on: manager),
      peerState: configured ? .wireGuardConfigured : .notSelected,
      lastError: configurationUnapproved ? "vpn configuration not approved" : nil
    )
  }
}

// MARK: - AgentTunnelControllerError

enum AgentTunnelControllerError: LocalizedError {
  case missingServerEndpoint
  case sessionUnavailable

  var errorCode: TunnelControlErrorCode {
    switch self {
    case .missingServerEndpoint:
      return .missingWireGuardConfigPath
    case .sessionUnavailable:
      return .runtimeStartFailure
    }
  }

  var message: String {
    switch self {
    case .missingServerEndpoint:
      return "wireguard config has no parseable peer Endpoint"
    case .sessionUnavailable:
      return "tunnel provider session is unavailable"
    }
  }

  var errorDescription: String? {
    message
  }
}

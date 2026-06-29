//
//  AgentTunnelController+Manager.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-26.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
@preconcurrency import NetworkExtension

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .daemon)

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
  func applyConfiguration(
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

  func save(manager: NETunnelProviderManager) async throws {
    try await resumeVoidContinuation { completion in
      manager.saveToPreferences(completionHandler: completion)
    }
  }

  func load(manager: NETunnelProviderManager) async throws {
    try await resumeVoidContinuation { completion in
      manager.loadFromPreferences(completionHandler: completion)
    }
  }

  func remove(manager: NETunnelProviderManager) async throws {
    try await resumeVoidContinuation { completion in
      manager.removeFromPreferences(completionHandler: completion)
    }
  }

  func startSession(on manager: NETunnelProviderManager) throws {
    guard let session = manager.connection as? NETunnelProviderSession else {
      throw AgentTunnelControllerError.sessionUnavailable
    }
    try session.startTunnel(options: nil)
  }

  func stopSession(on manager: NETunnelProviderManager) {
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

  func observeStatus(on manager: NETunnelProviderManager) {
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

  func snapshot(from manager: NETunnelProviderManager) -> TunnelDaemonStatusSnapshot {
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

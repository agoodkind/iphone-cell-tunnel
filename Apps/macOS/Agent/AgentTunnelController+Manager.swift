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
    // Look again before deciding. Another caller can resolve or stage a profile while
    // this one is suspended in the load, and its own read happened before that, so
    // taking the result anyway would replace a staged profile with a blank one. The
    // session, the status observer, and the pending save all belong to the object that
    // was staged, so losing it strands them where nothing refers to them again.
    if let manager = currentManager() {
      return manager
    }
    let resolved = preferredManager(from: managers) ?? NETunnelProviderManager()
    setManager(resolved)
    logger.notice("agent resolved tunnel manager count=\(managers.count, privacy: .public)")
    return resolved
  }

  /// Picks this agent's profile out of a freshly loaded set. Loading returns every
  /// profile this app saved and promises no order, so every caller chooses the same
  /// way and none can land on a different profile than the others when more than one
  /// exists. Preferring the tunnel's own name still cannot separate two profiles that
  /// share it, which stays an argument for never leaving a second one behind.
  func preferredManager(
    from managers: [NETunnelProviderManager]
  ) -> NETunnelProviderManager? {
    let named = managers.first { manager in
      manager.localizedDescription == Self.tunnelLocalizedDescription
    }
    return named ?? managers.first
  }

  /// The saved profile's state as the system currently holds it.
  ///
  /// This loads its own copy rather than re-reading the cached manager, for two
  /// reasons. A reload writes every setting back onto the object it is given, so
  /// re-reading the shared manager would overwrite configuration that a concurrent
  /// start had staged but not yet saved. A reload also reports no error when the
  /// profile is simply absent, so it cannot be used to tell "nothing saved" apart
  /// from "load failed" the way a thrown error would.
  ///
  /// A read that fails leaves the state unknown, reported as `nil`, and the app then
  /// keeps whatever it last knew rather than assuming the profile is fine.
  ///
  /// Finding no profile also retires the cached copy, which would otherwise keep
  /// describing a profile that has been deleted for as long as the agent runs, and
  /// would have the screen offer to route through something that is no longer there.
  func currentProfileState() async -> TunnelVPNProfileState? {
    do {
      let managers = try await loadAllManagers()
      guard let saved = preferredManager(from: managers),
        saved.protocolConfiguration != nil
      else {
        // Retire the cached copy, but not while a start is staging one: a first-ever
        // start leaves preferences empty until its save lands, and clearing then would
        // drop the profile that start is about to create.
        if settlingStartGeneration == nil {
          clearManager()
        }
        return .absent
      }
      return saved.isEnabled ? .enabled : .disabled
    } catch {
      logger.notice(
        """
        agent vpn profile state read failed \
        details=\(String(describing: error), privacy: .public) \
        recovery=report-unknown
        """
      )
      return nil
    }
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

  private func recordStatus(_ status: NEVPNStatus) async {
    logger.notice(
      "agent observed vpn status=\(self.statusDescription(status), privacy: .public)"
    )
    await reconcileRoutingIntent(with: status)
  }

  /// Drops the routing intent when the system takes the tunnel away underneath the
  /// app. A profile reports `invalid` once it no longer exists or is switched off, so
  /// seeing that while routing is still meant to be on means the session ended for a
  /// reason the app did not ask for. Without this the intent outlives the session: the
  /// screen keeps showing a routing switch that reads as connecting, and it stays that
  /// way after the user switches the profile back on, because nothing restarts the
  /// tunnel on its own.
  ///
  /// A stop the app itself requested clears the intent before the session ends, so
  /// this sees routing already off and does nothing. A start still settling is left
  /// alone too: enabling a switched-off profile is a supported way to start routing,
  /// and the profile reports itself unavailable until the system finishes enabling it,
  /// so acting then would cancel the very start that is about to fix it.
  private func reconcileRoutingIntent(with status: NEVPNStatus) async {
    guard status == .invalid, routingEnabled, settlingStartGeneration == nil else {
      return
    }
    // The notification arrives off the actor, so by the time this runs the user may
    // have asked to route again and the profile may already be on its way back. Acting
    // on the value captured at delivery would cancel that request, so the decision is
    // made against what the profile reports now. No cached profile at all is the same
    // conclusion by a different route, since the profile was found to be gone.
    if let cached = currentManager(), cached.connection.status != .invalid {
      return
    }
    logger.notice("agent routing intent dropped reason=profile-unavailable")
    await disableRouting()
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

  func snapshot(
    from manager: NETunnelProviderManager,
    profileState: TunnelVPNProfileState?
  ) -> TunnelDaemonStatusSnapshot {
    let status = manager.connection.status
    let configured = manager.protocolConfiguration != nil
    // A profile reports `invalid` when it has never been approved, when it is switched
    // off, and when it no longer exists, so the profile state is what separates them.
    // Only a profile that is switched on and still reads `invalid` is genuinely waiting
    // on approval. A switched-off one is reported through the profile state instead,
    // which names the situation and carries an action. A deleted one has nothing to
    // approve, and saying otherwise would strand the screen on an error instead of
    // letting it offer setup again, since the cached copy still describes the profile
    // that was removed. An unknown state keeps the original reading, so a failed read
    // never hides a real approval prompt.
    let profileAwaitsApproval = profileState == .enabled || profileState == nil
    let configurationUnapproved = status == .invalid && configured && profileAwaitsApproval
    return TunnelDaemonStatusSnapshot(
      running: isSessionActive(on: manager),
      peerState: configured ? .wireGuardConfigured : .notSelected,
      lastError: configurationUnapproved ? "vpn configuration not approved" : nil,
      vpnProfileState: profileState
    )
  }
}

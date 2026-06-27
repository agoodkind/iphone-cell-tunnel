//
//  PhoneRelayBackend.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-31.
//  Copyright © 2026, all rights reserved.
//

#if !targetEnvironment(macCatalyst)
  import CellTunnelCore
  import CellTunnelLog
  import Foundation
  @preconcurrency import NetworkExtension
  import UIKit

  private let logger = CellTunnelLog.logger(category: .relay)

  // MARK: - Constants

  private let tunnelProviderBundleSuffix = ".Tunnel"
  private let tunnelServerAddress = "Cell Tunnel"
  private let tunnelLocalizedDescription = "Cell Tunnel"
  private let invalidConfigurationError = "vpn configuration not approved"
  private let providerMessageTimeoutSeconds: Double = 5

  // MARK: - PhoneRelayBackend

  /// Drives the iPhone background tunnel for the shared relay UI. It loads or
  /// creates the single tunnel manager that points at the embedded relay
  /// extension, enables on-demand so the system keeps the tunnel up, starts the
  /// session, and answers status readings by sending a provider message to the
  /// extension. The data plane lives in the extension, so this type owns no
  /// forwarder; it reflects the polled snapshot into a `RelayStatusSample`.
  @MainActor
  final class PhoneRelayBackend: RelayControlBackend {
    private var manager: NETunnelProviderManager?
    private var lastSample: RelayStatusSample?
    private var configurationChangeObserver: NSObjectProtocol?

    // In the simulator the Network Extension has no launchable nehelper to start
    // the packet tunnel, so the backend delegates to SimulatorRelayBackend, which
    // hosts the same relay runtime in-process. `isSimulator` is a stored flag read
    // at runtime, so the device tunnel code below the guard stays compiled in the
    // simulator slice and the dead-code gate covers it.
    private let simulatorProbe = SimulatorRelayBackend()

    #if targetEnvironment(simulator)
      private let isSimulator = true
    #else
      private let isSimulator = false
    #endif

    // The provider bundle id nests under the host app: the app's own bundle id
    // with a ".Tunnel" suffix matches PHONE_PROVIDER_BUNDLE_ID.
    private var providerBundleIdentifier: String {
      (Bundle.main.bundleIdentifier ?? "") + tunnelProviderBundleSuffix
    }

    private var session: NETunnelProviderSession? {
      manager?.connection as? NETunnelProviderSession
    }

    // MARK: - Lifecycle

    func start() async {
      if isSimulator {
        await simulatorProbe.start()
        return
      }
      logger.notice("phone relay backend start requested")
      publishDeviceNameForRelayAdvertisement()
      UIApplication.shared.isIdleTimerDisabled = true
      do {
        let loadedManager = try await loadOrCreateManager()
        manager = loadedManager
        try startSessionIfNeeded(on: loadedManager)
        logger.notice("phone relay backend start completed")
      } catch {
        logger.error(
          """
          phone relay backend start failed \
          details=\(String(describing: error), privacy: .public) recovery=surface-to-ui
          """
        )
        lastSample = errorSample(message: String(describing: error))
      }
    }

    // MARK: - Sampling

    func sample() async -> RelayStatusSample? {
      if isSimulator {
        return await simulatorProbe.sample()
      }
      guard let session else {
        return lastSample
      }
      do {
        let response = try await sendStatusRequest(on: session)
        guard let snapshot = response.status else {
          logger.notice("phone relay status poll returned no status payload")
          return fallbackSample(connectionStatus: session.status)
        }
        return makeSample(snapshot: snapshot, connectionStatus: session.status)
      } catch {
        logger.error(
          """
          phone relay status poll failed \
          details=\(String(describing: error), privacy: .public) \
          recovery=fallback-from-connection
          """
        )
        return fallbackSample(connectionStatus: session.status)
      }
    }

    private func makeSample(
      snapshot: TunnelDaemonStatusSnapshot, connectionStatus: NEVPNStatus
    ) -> RelayStatusSample {
      var merged = snapshot
      merged.running = snapshot.running || isConnectionRunning(connectionStatus)
      var sample = RelayStatusSample(snapshot: merged)
      sample.isTunnelInstalled = hasInstalledTunnel
      lastSample = sample
      return sample
    }

    // On the iPhone the tunnel is installed once its own provider manager is saved
    // with a protocol configuration, independent of the running state, so the
    // setup tier clears as soon as the profile exists.
    private var hasInstalledTunnel: Bool {
      manager?.protocolConfiguration != nil
    }

    // Reuses the last good reading so a momentary missing payload does not blank
    // the screen or corrupt the throughput delta; only the running flag and the
    // unapproved-configuration error are refreshed from the connection.
    private func fallbackSample(connectionStatus: NEVPNStatus) -> RelayStatusSample {
      var sample = lastSample ?? emptySample()
      sample.isRunning = isConnectionRunning(connectionStatus)
      sample.isTunnelInstalled = hasInstalledTunnel
      if connectionStatus == .invalid {
        sample.lastError = invalidConfigurationError
      }
      logger.debug(
        "phone relay fallback sample running=\(sample.isRunning, privacy: .public)")
      lastSample = sample
      return sample
    }

    private func emptySample() -> RelayStatusSample {
      RelayStatusSample(snapshot: TunnelDaemonStatusSnapshot())
    }

    private func errorSample(message: String) -> RelayStatusSample {
      var sample = emptySample()
      sample.lastError = message
      return sample
    }

    private func isConnectionRunning(_ status: NEVPNStatus) -> Bool {
      switch status {
      case .connected, .connecting, .reasserting:
        return true
      default:
        return false
      }
    }

    // MARK: - Device name

    // The background extension has no UIKit and otherwise advertises the process
    // host name, so the app publishes the user-visible device name into the
    // shared app group for the provider to use as the Bonjour service name.
    private func publishDeviceNameForRelayAdvertisement() {
      let defaults = UserDefaults(suiteName: cellTunnelAppGroupIdentifier) ?? .standard
      storeRelayServiceDeviceName(UIDevice.current.name, defaults: defaults)
      logger.notice("phone relay backend published device name for relay advertisement")
    }

    // MARK: - Manager

    // Reuses the first manager that already targets this provider bundle id,
    // otherwise builds a fresh one. Either way it persists an enabled
    // NETunnelProviderProtocol with on-demand rules so the system keeps the
    // tunnel connected, then reloads so the connection is usable.
    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
      logger.notice("phone relay backend loading managers from preferences")
      let managers = try await NETunnelProviderManager.loadAllFromPreferences()
      let existing = managers.first { candidate in
        let tunnelProtocol = candidate.protocolConfiguration as? NETunnelProviderProtocol
        return tunnelProtocol?.providerBundleIdentifier == providerBundleIdentifier
      }
      let resolvedManager = existing ?? NETunnelProviderManager()

      let tunnelProtocol = NETunnelProviderProtocol()
      tunnelProtocol.providerBundleIdentifier = providerBundleIdentifier
      tunnelProtocol.serverAddress = tunnelServerAddress
      resolvedManager.protocolConfiguration = tunnelProtocol
      resolvedManager.localizedDescription = tunnelLocalizedDescription
      resolvedManager.isEnabled = true
      resolvedManager.isOnDemandEnabled = true
      let connectRule = NEOnDemandRuleConnect()
      connectRule.interfaceTypeMatch = .any
      resolvedManager.onDemandRules = [connectRule]

      try await resolvedManager.saveToPreferences()
      try await resolvedManager.loadFromPreferences()
      logger.notice(
        "phone relay backend manager saved reused=\(existing != nil, privacy: .public)"
      )
      return resolvedManager
    }

    // Mirrors the macOS agent isSessionActive gate so a tunnel the system
    // already brought up via on-demand is not torn down and restarted on launch.
    private func startSessionIfNeeded(on manager: NETunnelProviderManager) throws {
      guard let tunnelSession = manager.connection as? NETunnelProviderSession else {
        throw PhoneRelayBackendError.sessionUnavailable
      }
      guard !isConnectionRunning(tunnelSession.status) else {
        logger.notice("phone relay backend session already active; skipping start")
        return
      }
      try tunnelSession.startTunnel(options: nil)
      logger.notice("phone relay backend startTunnel issued")
    }

    // MARK: - Provider message

    // Sends the routing choice to the extension, which forwards it to the agent
    // over the control link. The agent owns the routes.
    func setRouting(enabled: Bool) async {
      if isSimulator {
        await simulatorProbe.setRouting(enabled: enabled)
        return
      }
      guard let session else {
        logger.notice("phone relay backend routing change ignored: no session")
        return
      }
      do {
        let payload = try JSONEncoder().encode(
          ProviderControlEnvelope(request: .setRoutingEnabled(enabled: enabled)))
        _ = try await sendProviderMessage(payload, on: session)
        logger.notice(
          "phone relay backend routing sent enabled=\(enabled, privacy: .public)")
      } catch {
        logger.error(
          """
          phone relay backend routing change failed \
          details=\(String(describing: error), privacy: .public) recovery=keep-state
          """
        )
      }
    }

    // MARK: - Peer selection

    // The iPhone is a dumb dialer with no manual picker, so it auto-dials the first
    // discovered Mac when none is selected.
    var autoSelectsDiscoveredPeer: Bool {
      true
    }

    // Forwards the peer selection to the extension's relay runtime over a provider
    // message, which dials the chosen Mac control service.
    func selectPeer(id: String) async {
      if isSimulator {
        await simulatorProbe.selectPeer(id: id)
        return
      }
      guard let session else {
        logger.notice("phone relay backend peer selection ignored: no session")
        return
      }
      do {
        let payload = try JSONEncoder().encode(
          ProviderControlEnvelope(request: .selectPeer(id: id)))
        _ = try await sendProviderMessage(payload, on: session)
        logger.notice(
          "phone relay backend peer selection sent id=\(id, privacy: .public)")
      } catch {
        logger.error(
          """
          phone relay backend peer selection failed \
          details=\(String(describing: error), privacy: .public) recovery=keep-state
          """
        )
      }
    }

    func selectEgressPeer(id _: String) async {
      await Task.yield()
    }

    // MARK: - Tunnel install

    // The iPhone tunnel carries no WireGuard config, so installing it saves and
    // starts the provider manager through the existing start path.
    func installTunnel(configURL _: URL) async {
      if isSimulator {
        await simulatorProbe.installTunnel(configURL: URL(fileURLWithPath: "/"))
        return
      }
      logger.notice("phone relay backend install tunnel: starting session")
      await start()
    }

    // MARK: - Config library

    // The iPhone hosts no config library; its tunnel carries no WireGuard config.
    func loadConfigText(id _: UUID) async -> String? {
      await Task.yield()
      return nil
    }

    func importConfig(url _: URL, name _: String) async {
      await Task.yield()
    }

    func activateConfig(id _: UUID) async {
      await Task.yield()
    }

    func saveConfigEdit(id _: UUID, text _: String) async {
      await Task.yield()
    }

    func renameConfig(id _: UUID, name _: String) async {
      await Task.yield()
    }

    func deleteConfig(id _: UUID) async {
      await Task.yield()
    }

    private func sendStatusRequest(
      on session: NETunnelProviderSession
    ) async throws -> ProviderControlResponse {
      let payload = try JSONEncoder().encode(ProviderControlEnvelope(request: .status))
      let responseData = try await sendProviderMessage(payload, on: session)
      return try JSONDecoder().decode(ProviderControlResponse.self, from: responseData)
    }

    // Bridges the Objective-C completion callback into async/await with a single
    // resume guarded by a lock plus a timeout so a silent extension cannot hang
    // the poll loop forever.
    private func sendProviderMessage(
      _ payload: Data,
      on session: NETunnelProviderSession
    ) async throws -> Data {
      try await withCheckedThrowingContinuation { continuation in
        let box = ProviderMessageContinuationBox(continuation: continuation)
        do {
          try session.sendProviderMessage(payload) { response in
            box.resume(with: response)
          }
        } catch {
          logger.error(
            """
            phone relay status provider message send failed \
            details=\(String(describing: error), privacy: .public) \
            recovery=resume-continuation-with-error
            """
          )
          box.resumeOnce(throwing: error)
        }
        box.scheduleTimeout(providerMessageTimeoutSeconds)
      }
    }
  }

  // MARK: - Provisioning

  extension PhoneRelayBackend {
    /// Reads saved NetworkExtension preferences without saving a tunnel manager.
    func tunnelProvisioned() async -> Bool {
      if isSimulator {
        return true
      }
      registerConfigurationChangeObserver()
      logger.notice("phone relay backend reading saved tunnel state")
      do {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let existing = managers.first { candidate in
          let tunnelProtocol = candidate.protocolConfiguration as? NETunnelProviderProtocol
          return tunnelProtocol?.providerBundleIdentifier == providerBundleIdentifier
        }
        manager = existing
        guard existing != nil else {
          lastSample = emptySample()
          logger.notice("phone relay backend saved tunnel absent")
          return false
        }
        let provisioned = manager?.protocolConfiguration != nil
        logger.notice(
          "phone relay backend saved tunnel provisioned=\(provisioned, privacy: .public)"
        )
        return provisioned
      } catch {
        logger.error(
          """
          phone relay backend saved tunnel read failed \
          details=\(String(describing: error), privacy: .public) \
          recovery=use-current-manager-state
          """
        )
        return hasInstalledTunnel
      }
    }

    private func registerConfigurationChangeObserver() {
      guard configurationChangeObserver == nil else {
        return
      }
      configurationChangeObserver = NotificationCenter.default.addObserver(
        forName: .NEVPNConfigurationChange,
        object: nil,
        queue: nil
      ) { @Sendable [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self else {
            return
          }
          _ = await tunnelProvisioned()
        }
      }
      logger.notice("phone relay backend registered vpn configuration change observer")
    }
  }

  // MARK: - PhoneRelayBackendError

  enum PhoneRelayBackendError: LocalizedError {
    case sessionUnavailable

    var errorDescription: String? {
      switch self {
      case .sessionUnavailable:
        return "tunnel provider session is unavailable"
      }
    }
  }

  // MARK: - ProviderMessageContinuationBox

  // Thread-safe one-shot bridge from the sendProviderMessage callback or the
  // timeout into a single continuation resume, matching the macOS agent box.
  private final class ProviderMessageContinuationBox: @unchecked Sendable {
    private let continuation: CheckedContinuation<Data, Error>
    private let lock = NSLock()
    private var finished = false

    init(continuation: CheckedContinuation<Data, Error>) {
      self.continuation = continuation
    }

    func resume(with response: Data?) {
      guard let response else {
        resumeOnce(
          throwing: TunnelDaemonError.transportFailure(
            "extension returned no payload for status"
          )
        )
        return
      }
      resumeOnce(returning: response)
    }

    func scheduleTimeout(_ timeoutSeconds: Double) {
      DispatchQueue.global(qos: .userInitiated)
        .asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
          self?.resumeOnce(
            throwing: TunnelDaemonError.transportFailure("extension message timed out")
          )
        }
    }

    func resumeOnce(returning value: Data) {
      guard claim() else {
        return
      }
      continuation.resume(returning: value)
    }

    func resumeOnce(throwing error: Error) {
      guard claim() else {
        return
      }
      continuation.resume(throwing: error)
    }

    private func claim() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      if finished {
        return false
      }
      finished = true
      return true
    }
  }

#endif

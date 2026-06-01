//
//  PhoneRelayBackend.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-31.
//  Copyright © 2026
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
    private let relayStoppedStateText = "Stopped"
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

        func stop() async {
            logger.notice("phone relay backend stop requested")
            UIApplication.shared.isIdleTimerDisabled = false
            guard let manager else {
                logger.notice("phone relay backend stop ignored because no manager is loaded")
                return
            }
            // On-demand keeps reconnecting the tunnel, so disable the rules and
            // persist before stopping; start re-enables them via loadOrCreateManager.
            manager.isOnDemandEnabled = false
            do {
                try await manager.saveToPreferences()
            } catch {
                logger.error(
                    """
                    phone relay backend failed disabling on-demand before stop \
                    details=\(String(describing: error), privacy: .public) recovery=continue-stop
                    """
                )
            }
            guard let session = manager.connection as? NETunnelProviderSession else {
                logger.notice("phone relay backend stop ignored because session is unavailable")
                return
            }
            session.stopTunnel()
        }

        // MARK: - Sampling

        func sample() async -> RelayStatusSample? {
            guard let session else {
                return nil
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
            let sample = RelayStatusSample(
                isRunning: snapshot.running || isConnectionRunning(connectionStatus),
                relayStateDescription: snapshot.relayState ?? relayStoppedStateText,
                connectedPeerName: snapshot.connectedPeerName,
                cellularPath: snapshot.cellularPath ?? CellularPathSnapshot(),
                counters: snapshot.phoneCounters ?? TunnelCounters(),
                lastError: snapshot.lastError
            )
            lastSample = sample
            return sample
        }

        // Reuses the last good reading so a momentary missing payload does not blank
        // the screen or corrupt the throughput delta; only the running flag and the
        // unapproved-configuration error are refreshed from the connection.
        private func fallbackSample(connectionStatus: NEVPNStatus) -> RelayStatusSample {
            var sample = lastSample ?? emptySample()
            sample.isRunning = isConnectionRunning(connectionStatus)
            if connectionStatus == .invalid {
                sample.lastError = invalidConfigurationError
            }
            logger.debug(
                "phone relay fallback sample running=\(sample.isRunning, privacy: .public)")
            lastSample = sample
            return sample
        }

        private func emptySample() -> RelayStatusSample {
            RelayStatusSample(
                isRunning: false,
                relayStateDescription: relayStoppedStateText,
                connectedPeerName: nil,
                cellularPath: CellularPathSnapshot(),
                counters: TunnelCounters(),
                lastError: nil
            )
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
            let manager = existing ?? NETunnelProviderManager()

            let tunnelProtocol = NETunnelProviderProtocol()
            tunnelProtocol.providerBundleIdentifier = providerBundleIdentifier
            tunnelProtocol.serverAddress = tunnelServerAddress
            manager.protocolConfiguration = tunnelProtocol
            manager.localizedDescription = tunnelLocalizedDescription
            manager.isEnabled = true
            manager.isOnDemandEnabled = true
            let connectRule = NEOnDemandRuleConnect()
            connectRule.interfaceTypeMatch = .any
            manager.onDemandRules = [connectRule]

            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            logger.notice(
                "phone relay backend manager saved reused=\(existing != nil, privacy: .public)"
            )
            return manager
        }

        // Mirrors the macOS agent isSessionActive gate so a tunnel the system
        // already brought up via on-demand is not torn down and restarted on launch.
        private func startSessionIfNeeded(on manager: NETunnelProviderManager) throws {
            guard let session = manager.connection as? NETunnelProviderSession else {
                throw PhoneRelayBackendError.sessionUnavailable
            }
            guard !isConnectionRunning(session.status) else {
                logger.notice("phone relay backend session already active; skipping start")
                return
            }
            try session.startTunnel(options: nil)
            logger.notice("phone relay backend startTunnel issued")
        }

        // MARK: - Provider message

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

    // MARK: - Developer console

    #if DEBUG
        extension PhoneRelayBackend: RelayDebugBackend {
            func restart() async {
                logger.notice("phone relay backend restart requested")
                await stop()
                await start()
            }

            func environmentChecks() async -> [TunnelEnvironmentCheckResult] {
                // The iPhone has no agent environment report; yield to keep this a
                // real suspension point for the async contract.
                await Task.yield()
                return []
            }

            func probeServer(endpoint: RelayEndpoint) async -> DebugProbeResult {
                await RelayServerProbe.probeServer(endpoint: endpoint, pinCellular: true)
            }
        }
    #endif
#endif

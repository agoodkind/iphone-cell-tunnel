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
import WireGuardKit

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .daemon)

private let providerBundleIdentifier = tunnelProviderBundleIdentifier
private let providerConfigWireGuardKey = "wireguardConfig"
private let providerConfigRelayServiceKey = "selectedRelayServiceName"
private let tunnelLocalizedDescription = "Cell Tunnel"
private let tunnelServerAddressPlaceholder = "iPhone Cellular Relay"
private let providerMessageTimeoutSeconds: Double = 5

private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private typealias ManagerListBox = UncheckedSendableBox<[NETunnelProviderManager]>

// MARK: - AgentTunnelController

actor AgentTunnelController {
    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var latestStatus: NEVPNStatus = .invalid
    var controlListener: AgentControlListener?
    let relayBridge = AgentRelayBridge()
    let relayBrowser = RelayDeviceBrowser()

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
            latestStatus = .invalid
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
            return AgentControlResponse(status: status)
        }
        return AgentControlResponse(status: snapshot(from: manager))
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
        latestStatus = status
        logger.notice(
            "agent observed vpn status=\(self.statusDescription(status), privacy: .public)"
        )
    }

    // Tells the Mac extension to install or withdraw routes as the iPhone relay
    // link comes and goes, so routes track the link rather than tunnel start.
    func signalRouteState(_ installed: Bool) async {
        guard let manager else {
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
        return TunnelDaemonStatusSnapshot(
            running: isSessionActive(on: manager),
            peerState: configured ? .wireGuardConfigured : .notSelected,
            lastError: status == .invalid ? "vpn configuration not approved" : nil
        )
    }

    func readConfigText(at path: String) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return try String(contentsOf: URL(fileURLWithPath: expanded), encoding: .utf8)
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

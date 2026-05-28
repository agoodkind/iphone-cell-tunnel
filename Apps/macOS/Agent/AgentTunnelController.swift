import CellTunnelCore
import CellTunnelLog
import Foundation
@preconcurrency import NetworkExtension

private let logger = CellTunnelLog.logger(category: .daemon)

private let providerBundleIdentifier = "io.goodkind.CellTunnelAgent.TunnelProvider"
private let providerConfigWireGuardKey = "wireguardConfig"
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

actor AgentTunnelController {
    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var latestStatus: NEVPNStatus = .invalid

    func handle(request: AgentControlRequest) async -> AgentControlResponse {
        switch request {
        case .status:
            return await handleStatus()
        case .check:
            return await handleCheck()
        case .startTunnel(let settings):
            return await handleStartTunnel(settings: settings)
        case .stopTunnel:
            return await handleStopTunnel()
        case .startRelayDiscovery:
            return await forwardDiscovery(operationName: "startRelayDiscovery")
        case .stopRelayDiscovery:
            return await forwardDiscovery(operationName: "stopRelayDiscovery")
        case .listRelayServices:
            return await forwardDiscovery(operationName: "listRelayServices")
        case .selectRelayService:
            return failure(
                errorCode: .relaySelectionRequired,
                message: "relay selection happens inside the extension during start"
            )
        }
    }

    private func handleStatus() async -> AgentControlResponse {
        do {
            let manager = try await loadOrCreateManager()
            guard isSessionActive(on: manager) else {
                return AgentControlResponse(status: snapshot(from: manager))
            }
            return try await forwardStatus(on: manager)
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
            let manager = try await loadOrCreateManager()
            checks.append(
                TunnelEnvironmentCheckResult(
                    name: "configuration_present",
                    value: String(manager.protocolConfiguration != nil)
                )
            )
            checks.append(
                TunnelEnvironmentCheckResult(
                    name: "vpn_status",
                    value: statusDescription(manager.connection.status)
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
            let manager = try await loadOrCreateManager()
            applyConfiguration(to: manager, wireGuardConfig: configText)
            try await save(manager: manager)
            try await load(manager: manager)
            observeStatus(on: manager)
            try startSession(on: manager)
            logger.notice("agent tunnel start requested")
            return AgentControlResponse(status: snapshot(from: manager))
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
            let manager = try await loadOrCreateManager()
            stopSession(on: manager)
            logger.notice("agent tunnel stop requested")
            return AgentControlResponse(status: snapshot(from: manager))
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

    private func forwardDiscovery(operationName: String) async -> AgentControlResponse {
        do {
            let manager = try await loadOrCreateManager()
            guard isSessionActive(on: manager) else {
                return AgentControlResponse(discovery: TunnelDiscoverySnapshot())
            }
            let response = try await forward(
                request: .discoverySnapshot,
                on: manager,
                operationName: operationName
            )
            if let failureMessage = response.failureMessage {
                return failure(errorCode: .discoveryUnavailable, message: failureMessage)
            }
            return AgentControlResponse(discovery: response.discovery ?? TunnelDiscoverySnapshot())
        } catch {
            logger.error(
                """
                \(operationName) agent operation caught error \
                details=\(String(describing: error), privacy: .public) \
                recovery=return-failure-response
                """
            )
            return failure(from: error)
        }
    }

    private func forwardStatus(
        on manager: NETunnelProviderManager
    ) async throws -> AgentControlResponse {
        let response = try await forward(request: .status, on: manager, operationName: "status")
        if let status = response.status {
            return AgentControlResponse(status: status)
        }
        return AgentControlResponse(status: snapshot(from: manager))
    }
}

extension AgentTunnelController {
    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        if let manager {
            return manager
        }
        let managers = try await loadAllManagers()
        let resolved = managers.first ?? NETunnelProviderManager()
        manager = resolved
        logger.notice("agent resolved tunnel manager count=\(managers.count, privacy: .public)")
        return resolved
    }

    private func loadAllManagers() async throws -> [NETunnelProviderManager] {
        try await NETunnelProviderManager.loadAllFromPreferences()
    }

    private func applyConfiguration(
        to manager: NETunnelProviderManager,
        wireGuardConfig: String
    ) {
        let providerProtocol = NETunnelProviderProtocol()
        providerProtocol.providerBundleIdentifier = providerBundleIdentifier
        providerProtocol.serverAddress = tunnelServerAddressPlaceholder
        providerProtocol.providerConfiguration = [providerConfigWireGuardKey: wireGuardConfig]
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

    private func resumeVoidContinuation(
        _ body: (@escaping @Sendable (Error?) -> Void) -> Void
    ) async throws {
        let _: Void = try await withCheckedThrowingContinuation { continuation in
            body { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            }
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

    private func isSessionActive(on manager: NETunnelProviderManager) -> Bool {
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

    private func forward(
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

    private func readConfigText(at path: String) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return try String(contentsOf: URL(fileURLWithPath: expanded), encoding: .utf8)
    }

    private func statusDescription(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid:
            return "invalid"
        case .disconnected:
            return "disconnected"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .reasserting:
            return "reasserting"
        case .disconnecting:
            return "disconnecting"
        @unknown default:
            return "unknown"
        }
    }

    private func failure(from error: Error) -> AgentControlResponse {
        if let controllerError = error as? AgentTunnelControllerError {
            return failure(errorCode: controllerError.errorCode, message: controllerError.message)
        }
        return failure(errorCode: .internal, message: error.localizedDescription)
    }

    private func failure(
        errorCode: TunnelControlErrorCode,
        message: String
    ) -> AgentControlResponse {
        AgentControlResponse(failure: AgentControlFailure(errorCode: errorCode, message: message))
    }
}

enum AgentTunnelControllerError: LocalizedError {
    case sessionUnavailable

    var errorCode: TunnelControlErrorCode {
        switch self {
        case .sessionUnavailable:
            return .runtimeStartFailure
        }
    }

    var message: String {
        switch self {
        case .sessionUnavailable:
            return "tunnel provider session is unavailable"
        }
    }

    var errorDescription: String? {
        message
    }
}

private final class ProviderMessageContinuationBox: @unchecked Sendable {
    private let continuation: CheckedContinuation<Data, Error>
    private let operationName: String
    private let lock = NSLock()
    private var finished = false

    init(continuation: CheckedContinuation<Data, Error>, operationName: String) {
        self.continuation = continuation
        self.operationName = operationName
    }

    func resume(with response: Data?) {
        guard let response else {
            resumeOnce(
                throwing: TunnelDaemonError.transportFailure(
                    "extension returned no payload for \(operationName)"
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

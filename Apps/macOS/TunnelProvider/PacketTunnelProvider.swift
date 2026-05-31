import CellTunnelCore
import CellTunnelLog
import Foundation
import Network
import NetworkExtension
import Synchronization
import WireGuardKit

private let logger = CellTunnelLog.logger(category: .daemon)

private let providerConfigWireGuardKey = "wireguardConfig"

// The Mac tunnel extension reaches the relay data plane by dialing the agent on
// the loopback interface. The agent hosts the relay listener and bridges to the
// iPhone, because a listener inside this extension cannot receive inbound.
private let agentLoopbackHost = "127.0.0.1"

// The completion handler arrives from Objective-C without a Sendable marking;
// box it so the start Task can call it across the concurrency boundary.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

enum PacketTunnelProviderError: LocalizedError {
    case missingWireGuardConfig

    var errorDescription: String? {
        switch self {
        case .missingWireGuardConfig:
            return "providerConfiguration is missing \(providerConfigWireGuardKey)"
        }
    }
}

// NEPacketTunnelProvider serializes the tunnel lifecycle callbacks, so the
// stored state mutated across start and stop is never touched concurrently.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let relayMetrics: RelayMetrics
    private let relayTransport: RelayTransport
    private let wireGuardRuntime = WireGuardRuntime()
    private var wireGuardRelayBind: WireGuardRelayBind?
    private var throughputLogger: RelayThroughputLogger?

    override init() {
        let metrics = RelayMetrics()
        relayMetrics = metrics
        relayTransport = RelayTransport(metrics: metrics)
        super.init()
        logger.notice("PacketTunnelProvider initialized")
    }

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let optionCount = options?.count ?? 0
        let handlerBox = UncheckedSendableBox(completionHandler)
        Task {
            do {
                try await runStartTunnel(optionCount: optionCount)
                handlerBox.value(nil)
            } catch {
                logger.error(
                    "tunnel start failed error=\(String(describing: error), privacy: .public) recovery=propagate-to-NE"
                )
                handlerBox.value(error)
            }
        }
    }

    private func runStartTunnel(optionCount: Int) async throws {
        logger.notice(
            "tunnel start request received optionsCount=\(optionCount, privacy: .public)"
        )

        let configText = try extractWireGuardConfigText()
        let parsedConfig = try WireGuardConfigParser.parse(configText)

        let agentEndpoint = Self.agentRelayEndpoint()
        try relayTransport.connect(to: agentEndpoint)
        logger.notice(
            "relay transport connected to agent loopback host=\(agentLoopbackHost, privacy: .public)"
        )

        let relayBind = WireGuardRelayBind(transport: relayTransport, metrics: relayMetrics)
        wireGuardRelayBind = relayBind

        let tunnelConfiguration = try WireGuardTunnelConfigBuilder.build(
            from: parsedConfig,
            name: "CellTunnel"
        )
        try await wireGuardRuntime.start(
            tunnelConfiguration: tunnelConfiguration,
            relayBind: relayBind,
            provider: self
        )
        logger.notice("tunnel runtime started")

        let throughputLogger = RelayThroughputLogger(metrics: relayMetrics)
        self.throughputLogger = throughputLogger
        throughputLogger.start()

        logger.notice("tunnel start completion handler called success=true")
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        logger.notice(
            "tunnel stop request received reason=\(String(describing: reason), privacy: .public)"
        )
        throughputLogger?.stop()
        throughputLogger = nil

        await wireGuardRuntime.stop()
        logger.notice("tunnel runtime stopped on shutdown")

        relayTransport.disconnect()
        logger.notice("relay transport disconnected on shutdown")

        wireGuardRelayBind = nil
        logger.notice("tunnel stop completion handler called")
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)?
    ) {
        let handlerBox = UncheckedSendableBox(completionHandler)
        let request: ProviderControlRequest
        do {
            request = try JSONDecoder().decode(
                ProviderControlEnvelope.self,
                from: messageData
            ).request
        } catch {
            logger.error(
                """
                app message decode failed \
                details=\(String(describing: error), privacy: .public) \
                recovery=reply-failure
                """
            )
            handlerBox.value?(encodeResponse(failureMessage: "decode failed"))
            return
        }
        let response = handleProviderRequest(request)
        handlerBox.value?(encodeResponse(response))
    }

    private func handleProviderRequest(
        _ request: ProviderControlRequest
    ) -> ProviderControlResponse {
        switch request {
        case .status:
            return ProviderControlResponse(status: currentStatusSnapshot())
        case .discoverySnapshot:
            // Discovery is owned by the agent; the extension holds no browser.
            return ProviderControlResponse(discovery: TunnelDiscoverySnapshot())
        }
    }

    private func currentStatusSnapshot() -> TunnelDaemonStatusSnapshot {
        let running = wireGuardRelayBind != nil
        return TunnelDaemonStatusSnapshot(
            running: running,
            routeState: running ? .installed : .notInstalled,
            peerState: running ? .wireGuardConfigured : .notSelected,
            macCounters: relayMetrics.snapshot()
        )
    }

    private func encodeResponse(_ response: ProviderControlResponse) -> Data? {
        do {
            return try JSONEncoder().encode(response)
        } catch {
            logger.error(
                """
                app message response encode failed \
                details=\(String(describing: error), privacy: .public) \
                recovery=reply-failure
                """
            )
            return encodeResponse(failureMessage: "encode failed")
        }
    }

    private func encodeResponse(failureMessage: String) -> Data? {
        do {
            return try JSONEncoder().encode(
                ProviderControlResponse(failureMessage: failureMessage)
            )
        } catch {
            logger.error(
                """
                app message failure encode failed \
                details=\(String(describing: error), privacy: .public) \
                recovery=reply-nil
                """
            )
            return nil
        }
    }

    private func extractWireGuardConfigText() throws -> String {
        guard let providerProtocol = protocolConfiguration as? NETunnelProviderProtocol else {
            throw PacketTunnelProviderError.missingWireGuardConfig
        }
        guard let providerConfiguration = providerProtocol.providerConfiguration else {
            throw PacketTunnelProviderError.missingWireGuardConfig
        }
        guard let configText = providerConfiguration[providerConfigWireGuardKey] as? String else {
            throw PacketTunnelProviderError.missingWireGuardConfig
        }
        return configText
    }

    // The relay transport dials the agent on the loopback interface; the agent
    // hosts the relay listener and bridges datagrams to the iPhone.
    private static func agentRelayEndpoint() -> NWEndpoint {
        NWEndpoint.hostPort(
            host: NWEndpoint.Host(agentLoopbackHost),
            port: resolvedRelayListenerPort()
        )
    }
}

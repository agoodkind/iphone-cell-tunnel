import CellTunnelCore
import CellTunnelLog
import Foundation
import Network
import NetworkExtension
import Synchronization
import WireGuardKit

private let logger = CellTunnelLog.logger(category: .daemon)

private let providerConfigWireGuardKey = "wireguardConfig"
private let providerConfigRelayServiceKey = "selectedRelayServiceName"
private let defaultDiscoveryTimeoutSeconds: UInt64 = 10
private let discoveryInitialPollNanoseconds: UInt64 = 200_000_000
private let discoveryMaxPollNanoseconds: UInt64 = 1_000_000_000
private let discoveryPollBackoffFactor: UInt64 = 2

// The completion handler arrives from Objective-C without a Sendable marking;
// box it so the start Task can call it across the concurrency boundary.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

enum PacketTunnelProviderError: LocalizedError {
    case discoveryTimeout
    case missingWireGuardConfig

    var errorDescription: String? {
        switch self {
        case .discoveryTimeout:
            return "discovery did not surface an iPhone relay before timeout"
        case .missingWireGuardConfig:
            return "providerConfiguration is missing \(providerConfigWireGuardKey)"
        }
    }
}

// NEPacketTunnelProvider serializes the tunnel lifecycle callbacks, so the
// stored state mutated across start and stop is never touched concurrently.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let discoveryManager = DiscoveryManager()
    private let relayMetrics: RelayMetrics
    private let relayTransport: RelayTransport
    private let wireGuardRuntime = WireGuardRuntime()
    private var controlChannel: ControlChannel?
    private var wireGuardRelayBind: WireGuardRelayBind?
    private var throughputLogger: RelayThroughputLogger?
    private var statusConsumerTask: Task<Void, Never>?
    private let phoneCounters = Mutex<TunnelCounters?>(nil)

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

        let selectedRelayServiceName = selectedRelayServiceName()
        let (relayServiceEndpoint, resolvedRelay) = try await discoverIPhoneRelay(
            preferredServiceName: selectedRelayServiceName
        )
        logger.notice(
            """
            discovery resolved host=\(resolvedRelay.host, privacy: .public) \
            port=\(resolvedRelay.port, privacy: .public)
            """
        )

        try relayTransport.connect(to: relayServiceEndpoint)
        logger.notice("relay transport connected")

        let serverRelayEndpoint = try makeServerRelayEndpoint(from: parsedConfig.peer)
        let channel = ControlChannel(serverEndpoint: serverRelayEndpoint)
        controlChannel = channel
        try await channel.start()
        logger.notice("control channel listener started")
        startPhoneCountersConsumer(channel: channel)

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

    // The iPhone pushes its relay counters on the control channel's Status message
    // every few seconds. Keep the latest copy so `currentStatusSnapshot()` can
    // report both ends. This runs off the datagram hot path.
    private func startPhoneCountersConsumer(channel: ControlChannel) {
        statusConsumerTask = Task { [weak self] in
            for await status in channel.statusStream {
                guard let self else {
                    return
                }
                if let counters = status.counters {
                    phoneCounters.withLock { $0 = counters }
                }
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        logger.notice(
            "tunnel stop request received reason=\(String(describing: reason), privacy: .public)"
        )
        throughputLogger?.stop()
        throughputLogger = nil
        statusConsumerTask?.cancel()
        statusConsumerTask = nil
        phoneCounters.withLock { $0 = nil }

        await wireGuardRuntime.stop()
        logger.notice("tunnel runtime stopped on shutdown")

        if let channel = controlChannel {
            await channel.stop()
            controlChannel = nil
        }
        logger.notice("control channel stopped on shutdown")

        relayTransport.disconnect()
        logger.notice("relay transport disconnected on shutdown")

        await discoveryManager.stop()
        logger.notice("discovery manager stopped on shutdown")

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
        Task {
            let response = await self.handleProviderRequest(request)
            handlerBox.value?(self.encodeResponse(response))
        }
    }

    private func handleProviderRequest(
        _ request: ProviderControlRequest
    ) async -> ProviderControlResponse {
        switch request {
        case .status:
            return ProviderControlResponse(status: currentStatusSnapshot())
        case .discoverySnapshot:
            return ProviderControlResponse(discovery: await currentDiscoverySnapshot())
        }
    }

    private func currentStatusSnapshot() -> TunnelDaemonStatusSnapshot {
        let running = wireGuardRelayBind != nil
        return TunnelDaemonStatusSnapshot(
            running: running,
            routeState: running ? .installed : .notInstalled,
            peerState: running ? .wireGuardConfigured : .notSelected,
            macCounters: relayMetrics.snapshot(),
            phoneCounters: phoneCounters.withLock { $0 }
        )
    }

    private func currentDiscoverySnapshot() async -> TunnelDiscoverySnapshot {
        let services = await discoveryManager.currentServices()
        let mapped = services.map { service in
            TunnelRelayService(
                id: service.identifier,
                serviceName: service.serviceName,
                serviceType: service.serviceType,
                domain: service.domain,
                interfaceIndex: service.interfaceIndex,
                hostName: service.resolvedEndpoint?.host ?? "",
                endpoints: service.resolvedEndpoint.map { [$0] } ?? [],
                preferredEndpoint: service.resolvedEndpoint,
                isSelected: false
            )
        }
        let phase: TunnelDiscoveryPhase = mapped.isEmpty ? .browsing : .ready
        return TunnelDiscoverySnapshot(phase: phase, services: mapped)
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

    // The agent writes the user's chosen relay into providerConfiguration when a
    // selection exists; absent that key, discovery keeps first-service behavior.
    private func selectedRelayServiceName() -> String? {
        guard let providerProtocol = protocolConfiguration as? NETunnelProviderProtocol else {
            return nil
        }
        guard let providerConfiguration = providerProtocol.providerConfiguration else {
            return nil
        }
        guard
            let name = providerConfiguration[providerConfigRelayServiceKey] as? String
        else {
            return nil
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        return trimmed
    }

    private func discoverIPhoneRelay(
        preferredServiceName: String?
    ) async throws -> (
        serviceEndpoint: NWEndpoint,
        resolved: TunnelRelayEndpoint
    ) {
        logger.notice(
            """
            discovery launch beginning \
            preferred=\(preferredServiceName ?? "none", privacy: .public)
            """
        )
        let waiter = DiscoveryServiceWaiter(preferredServiceName: preferredServiceName)
        await discoveryManager.start { services in
            waiter.deliver(services: services)
        }
        waiter.scheduleTimeout(seconds: defaultDiscoveryTimeoutSeconds)
        let initialServices = await discoveryManager.currentServices()
        if !initialServices.isEmpty {
            waiter.deliver(services: Set(initialServices))
        }
        let service = try await waiter.waitForService()
        logger.notice(
            "discovery service surfaced identifier=\(service.identifier, privacy: .public)"
        )
        // Connect to the Bonjour service endpoint so the Network framework
        // resolves and binds the link-local relay to its interface; a
        // reconstructed hostPort literal loses that scope and cannot route.
        guard
            let serviceEndpoint = await discoveryManager.endpoint(
                forIdentifier: service.identifier
            )
        else {
            throw PacketTunnelProviderError.discoveryTimeout
        }
        let resolved = try await discoveryManager.resolve(service.identifier)
        return (serviceEndpoint, resolved)
    }

    private func makeServerRelayEndpoint(
        from peer: WireGuardPeerSection
    ) throws -> RelayEndpoint {
        guard let wgEndpoint = peer.endpoint else {
            throw PacketTunnelProviderError.missingWireGuardConfig
        }
        let family: RelayAddressFamily = wgEndpoint.isIPv6Literal ? .ipv6 : .ipv4
        return RelayEndpoint(
            addressFamily: family,
            host: wgEndpoint.host,
            port: wgEndpoint.port
        )
    }
}

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network
import NetworkExtension
import WireGuardKit

private let logger = CellTunnelLog.logger(category: .daemon)

private let providerConfigWireGuardKey = "wireguardConfig"
private let defaultTunnelMTU: UInt16 = 1_280
private let defaultDiscoveryTimeoutSeconds: UInt64 = 10
private let ipv4PrefixLengthMax: Int = 32
private let ipv4OctetMask: UInt32 = 0xFF
private let ipv4OctetShift1: UInt32 = 24
private let ipv4OctetShift2: UInt32 = 16
private let ipv4OctetShift3: UInt32 = 8
private let discoveryInitialPollNanoseconds: UInt64 = 200_000_000
private let discoveryMaxPollNanoseconds: UInt64 = 1_000_000_000
private let discoveryPollBackoffFactor: UInt64 = 2
private let unspecifiedRemoteAddress = "0.0.0.0"

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
    case unsupportedRelayHost(String)

    var errorDescription: String? {
        switch self {
        case .discoveryTimeout:
            return "discovery did not surface an iPhone relay before timeout"
        case .missingWireGuardConfig:
            return "providerConfiguration is missing \(providerConfigWireGuardKey)"
        case .unsupportedRelayHost(let host):
            return "discovered relay host is not usable as NWEndpoint host=\(host)"
        }
    }
}

// NEPacketTunnelProvider serializes the tunnel lifecycle callbacks, so the
// stored state mutated across start and stop is never touched concurrently.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let discoveryManager = DiscoveryManager()
    private let relayTransport = RelayTransport()
    private let wireGuardRuntime = WireGuardRuntime()
    private var controlChannel: ControlChannel?
    private var wireGuardRelayBind: WireGuardRelayBind?

    override init() {
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
        let networkSettings = buildNetworkSettings(from: parsedConfig)
        try await setTunnelNetworkSettings(networkSettings)
        logger.notice(
            """
            network settings applied tunnelRemoteAddress=\(networkSettings.tunnelRemoteAddress, privacy: .public) \
            mtu=\(networkSettings.mtu?.intValue ?? 0, privacy: .public)
            """
        )

        let resolvedRelay = try await discoverIPhoneRelay()
        logger.notice(
            """
            discovery resolved host=\(resolvedRelay.host, privacy: .public) \
            port=\(resolvedRelay.port, privacy: .public)
            """
        )

        let relayNWEndpoint = try makeNWEndpoint(from: resolvedRelay)
        try relayTransport.connect(to: relayNWEndpoint)
        logger.notice("relay transport connected")

        let serverRelayEndpoint = try makeServerRelayEndpoint(from: parsedConfig.peer)
        let channel = ControlChannel(serverEndpoint: serverRelayEndpoint)
        controlChannel = channel
        try await channel.start()
        logger.notice("control channel handshake done")

        let relayBind = WireGuardRelayBind(transport: relayTransport)
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

        logger.notice("tunnel start completion handler called success=true")
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        logger.notice(
            "tunnel stop request received reason=\(String(describing: reason), privacy: .public)"
        )
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
            peerState: running ? .wireGuardConfigured : .notSelected
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

    private func buildNetworkSettings(
        from parsedConfig: WireGuardClientConfig
    ) -> NEPacketTunnelNetworkSettings {
        let remoteAddress = parsedConfig.peer.endpoint?.host ?? unspecifiedRemoteAddress
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)

        let ipv4Addresses = parsedConfig.interface.addresses.filter { $0.family == .ipv4 }
        if let ipv4 = ipv4Addresses.first {
            let ipv4Settings = NEIPv4Settings(
                addresses: [ipv4.address],
                subnetMasks: [ipv4SubnetMask(forPrefixLength: ipv4.prefixLength)]
            )
            ipv4Settings.includedRoutes = [NEIPv4Route.default()]
            settings.ipv4Settings = ipv4Settings
        }

        let ipv6Addresses = parsedConfig.interface.addresses.filter { $0.family == .ipv6 }
        if let ipv6 = ipv6Addresses.first {
            let ipv6Settings = NEIPv6Settings(
                addresses: [ipv6.address],
                networkPrefixLengths: [NSNumber(value: ipv6.prefixLength)]
            )
            ipv6Settings.includedRoutes = [NEIPv6Route.default()]
            settings.ipv6Settings = ipv6Settings
        }

        let mtuValue = parsedConfig.interface.mtu ?? Int(defaultTunnelMTU)
        settings.mtu = NSNumber(value: mtuValue)
        return settings
    }

    private func discoverIPhoneRelay() async throws -> TunnelRelayEndpoint {
        logger.notice("discovery launch beginning")
        let waiter = DiscoveryServiceWaiter()
        await discoveryManager.start { services in
            waiter.deliver(services: services)
        }
        waiter.scheduleTimeout(seconds: defaultDiscoveryTimeoutSeconds)
        let initialServices = await discoveryManager.currentServices()
        if !initialServices.isEmpty {
            waiter.deliver(services: Set(initialServices))
        }
        let firstService = try await waiter.waitForFirstService()
        logger.notice(
            "discovery first service surfaced identifier=\(firstService.identifier, privacy: .public)"
        )
        return try await discoveryManager.resolve(firstService.identifier)
    }

    private func makeNWEndpoint(from endpoint: TunnelRelayEndpoint) throws -> NWEndpoint {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: endpoint.port)) else {
            throw PacketTunnelProviderError.unsupportedRelayHost(endpoint.host)
        }
        let host = NWEndpoint.Host(endpoint.host)
        return NWEndpoint.hostPort(host: host, port: port)
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

    private func ipv4SubnetMask(forPrefixLength prefixLength: Int) -> String {
        guard prefixLength > 0 else {
            return unspecifiedRemoteAddress
        }
        let mask = ~UInt32(0) << (ipv4PrefixLengthMax - prefixLength)
        let octet1 = (mask >> ipv4OctetShift1) & ipv4OctetMask
        let octet2 = (mask >> ipv4OctetShift2) & ipv4OctetMask
        let octet3 = (mask >> ipv4OctetShift3) & ipv4OctetMask
        let octet4 = mask & ipv4OctetMask
        return "\(octet1).\(octet2).\(octet3).\(octet4)"
    }
}

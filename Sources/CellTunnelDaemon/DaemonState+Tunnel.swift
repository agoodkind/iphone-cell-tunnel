import CellTunnelCore
import CellTunnelLog
import Darwin
import Foundation
import Network

private let logger = CellTunnelLog.logger(category: .daemon)

extension DaemonState {
    func startTunnel(settings: TunnelStartSettings) async throws -> TunnelDaemonStatusSnapshot {
        try ensureNotRunning()
        let parsedConfig = try parseStartConfig(settings: settings)
        let relayModel = try resolveRelayEndpoint(override: settings.relayEndpoint)
        let nwRelay = try networkEndpoint(from: relayModel)

        let components = try await bringUpComponents(
            parsedConfig: parsedConfig,
            relayEndpoint: relayModel,
            nwRelayEndpoint: nwRelay
        )
        commit(components: components)
        applyRunningStatus(components: components)
        logger.notice(
            """
            daemon start completed interface=\(components.device.interfaceName, privacy: .public) \
            allowed_prefixes=\(components.plan.prefixes.count, privacy: .public) \
            relay=\(components.relayEndpoint.socketAddress, privacy: .public)
            """
        )
        return currentStatus()
    }

    func stopTunnel() async -> TunnelDaemonStatusSnapshot {
        if routesInstalled {
            do {
                try await helperClient.removeRoutes()
            } catch {
                logger.error(
                    "route remove failed error=\(String(describing: error), privacy: .public)"
                )
            }
            routesInstalled = false
        }
        if let runtime = wireGuardRuntime {
            await runtime.stop()
        }
        if let bridge = loopbackBridge {
            await bridge.stop()
        }
        relayTransport?.disconnect()
        if let device = utunDevice {
            Darwin.close(device.fileDescriptor)
        }
        if let channel = controlChannel {
            await channel.stop()
        }
        wireGuardRuntime = nil
        loopbackBridge = nil
        relayTransport = nil
        utunDevice = nil
        controlChannel = nil
        status.running = false
        status.routeState = .notInstalled
        status.peerState = .notSelected
        status.activeRelayEndpoint = nil
        logger.notice("daemon stop request applied")
        return currentStatus()
    }

    private func ensureNotRunning() throws {
        if wireGuardRuntime != nil {
            throw daemonError(
                code: .runtimeStartFailure,
                message: "tunnel already running"
            )
        }
    }

    private func parseStartConfig(
        settings: TunnelStartSettings
    ) throws -> WireGuardClientConfig {
        guard settings.isReadyToStart else {
            throw daemonError(
                code: .missingWireGuardConfigPath,
                message: "wireguard config path is required"
            )
        }
        let url = URL(fileURLWithPath: settings.wireGuardConfigPath)
        do {
            return try WireGuardConfigParser.load(from: url)
        } catch {
            throw daemonError(
                code: .runtimeStartFailure,
                message: "wireguard config parse failed: \(error.localizedDescription)"
            )
        }
    }

    private func bringUpComponents(
        parsedConfig: WireGuardClientConfig,
        relayEndpoint: TunnelRelayEndpoint,
        nwRelayEndpoint: NWEndpoint
    ) async throws -> TunnelComponents {
        let device = try await openUtun()
        var deviceCleanup = true
        defer {
            if deviceCleanup {
                Darwin.close(device.fileDescriptor)
            }
        }

        let transport = try startRelayTransport(endpoint: nwRelayEndpoint)
        var transportCleanup = true
        defer {
            if transportCleanup {
                transport.disconnect()
            }
        }

        let bridge = try await startLoopbackBridge(transport: transport)
        var bridgeCleanup = true
        defer {
            if bridgeCleanup {
                Task { await bridge.stop() }
            }
        }

        let controlChannel = try await startControlChannel(parsedConfig: parsedConfig)
        var controlCleanup = true
        defer {
            if controlCleanup {
                Task { await controlChannel.stop() }
            }
        }

        let loopbackEndpoint = WireGuardEndpoint(
            host: bridge.loopbackEndpoint.host,
            port: bridge.loopbackEndpoint.port,
            isIPv6Literal: false
        )
        let runtime = try await startWireGuardRuntime(
            parsedConfig: parsedConfig,
            utunFd: device.fileDescriptor,
            endpointOverride: loopbackEndpoint
        )
        var runtimeCleanup = true
        defer {
            if runtimeCleanup {
                Task { await runtime.stop() }
            }
        }

        let plan = RoutePlanBuilder.build(from: parsedConfig, interfaceName: device.interfaceName)
        try await installRoutes(plan: plan)

        deviceCleanup = false
        transportCleanup = false
        bridgeCleanup = false
        runtimeCleanup = false
        controlCleanup = false
        return TunnelComponents(
            device: device,
            transport: transport,
            bindBridge: bridge,
            runtime: runtime,
            controlChannel: controlChannel,
            parsedConfig: parsedConfig,
            relayEndpoint: relayEndpoint,
            plan: plan
        )
    }

    private func startLoopbackBridge(transport: RelayTransport) async throws -> LoopbackBindBridge {
        let bridge: LoopbackBindBridge
        do {
            bridge = try LoopbackBindBridge()
        } catch {
            throw daemonError(
                code: .runtimeStartFailure,
                message: "loopback bridge init failed: \(error.localizedDescription)"
            )
        }
        do {
            try await bridge.start(relay: transport)
        } catch {
            await bridge.stop()
            throw daemonError(
                code: .runtimeStartFailure,
                message: "loopback bridge start failed: \(error.localizedDescription)"
            )
        }
        return bridge
    }

    private func startControlChannel(
        parsedConfig: WireGuardClientConfig
    ) async throws -> ControlChannel {
        let endpoint = try wireGuardServerEndpoint(from: parsedConfig)
        let channel = ControlChannel(serverEndpoint: endpoint)
        do {
            try await channel.start()
        } catch {
            await channel.stop()
            throw daemonError(
                code: .runtimeStartFailure,
                message: "control channel start failed: \(error.localizedDescription)"
            )
        }
        logger.notice(
            """
            control channel established host=\(endpoint.host, privacy: .public) \
            port=\(endpoint.port, privacy: .public) \
            family=\(endpoint.addressFamily.rawValue, privacy: .public)
            """
        )
        return channel
    }

    private func wireGuardServerEndpoint(
        from parsedConfig: WireGuardClientConfig
    ) throws -> RelayEndpoint {
        guard let endpoint = parsedConfig.peer.endpoint else {
            throw daemonError(
                code: .runtimeStartFailure,
                message: "wireguard config missing peer endpoint"
            )
        }
        let family: RelayAddressFamily = endpoint.isIPv6Literal ? .ipv6 : .ipv4
        return RelayEndpoint(
            addressFamily: family,
            host: endpoint.host,
            port: endpoint.port
        )
    }

    private func startRelayTransport(endpoint: NWEndpoint) throws -> RelayTransport {
        let transport = RelayTransport()
        do {
            try transport.connect(to: endpoint)
        } catch {
            throw daemonError(
                code: .runtimeStartFailure,
                message: "relay transport connect failed: \(error.localizedDescription)"
            )
        }
        return transport
    }

    private func startWireGuardRuntime(
        parsedConfig: WireGuardClientConfig,
        utunFd: Int32,
        endpointOverride: WireGuardEndpoint?
    ) async throws -> WireGuardRuntime {
        let uapi = parsedConfig.uapiConfig(endpointOverride: endpointOverride)
        let runtime = WireGuardRuntime()
        do {
            try await runtime.start(uapiConfig: uapi, utunFd: utunFd)
        } catch {
            throw daemonError(
                code: .runtimeStartFailure,
                message: "wireguard runtime start failed: \(error.localizedDescription)"
            )
        }
        return runtime
    }

    private func installRoutes(plan: RoutePlan) async throws {
        let prefixes = plan.prefixes.map(\.helperPrefix)
        do {
            try await helperClient.installRoutes(prefixes, onInterface: plan.interfaceName)
        } catch {
            throw daemonError(
                code: .runtimeStartFailure,
                message: "route install failed: \(error.localizedDescription)"
            )
        }
        routesInstalled = true
    }

    private func commit(components: TunnelComponents) {
        utunDevice = components.device
        relayTransport = components.transport
        loopbackBridge = components.bindBridge
        wireGuardRuntime = components.runtime
        controlChannel = components.controlChannel
    }

    private func applyRunningStatus(components: TunnelComponents) {
        let ipv4 = components.parsedConfig.interface.addresses.first { $0.family == .ipv4 }
        let ipv6 = components.parsedConfig.interface.addresses.first { $0.family == .ipv6 }
        status.running = true
        status.routeState = .installed
        status.peerState = .wireGuardConfigured
        status.activeRelayEndpoint = components.relayEndpoint
        status.ipv4Address = ipv4?.address ?? ""
        status.ipv6Address = ipv6?.address ?? ""
        status.lastError = nil
    }

    private func openUtun() async throws -> OpenedUtun {
        do {
            let result = try await helperClient.openUtunDevice()
            return OpenedUtun(
                fileDescriptor: result.fileDescriptor,
                interfaceName: result.interfaceName
            )
        } catch {
            throw daemonError(
                code: .runtimeStartFailure,
                message: "utun open failed: \(error.localizedDescription)"
            )
        }
    }

    private func resolveRelayEndpoint(
        override: TunnelRelayEndpoint?
    ) throws -> TunnelRelayEndpoint {
        if let override, override.isConfigured {
            return override
        }
        if let selected = discovery.selectedEndpoint, selected.isConfigured {
            return selected
        }
        throw daemonError(
            code: .relaySelectionRequired,
            message: "no relay endpoint available; pass --relay-endpoint or select a discovered service"
        )
    }

    private func networkEndpoint(from endpoint: TunnelRelayEndpoint) throws -> NWEndpoint {
        guard let port = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else {
            throw daemonError(
                code: .invalidRelayEndpoint,
                message: "relay endpoint port out of range: \(endpoint.port)"
            )
        }
        let host = NWEndpoint.Host(endpoint.host)
        return NWEndpoint.hostPort(host: host, port: port)
    }

}

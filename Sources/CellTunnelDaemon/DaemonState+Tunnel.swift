import CellTunnelCore
import CellTunnelLog
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
        if let manager = routeManager {
            do {
                try manager.removeAll()
            } catch {
                logger.error(
                    "route remove failed error=\(String(describing: error), privacy: .public)"
                )
            }
        }
        if let runtime = wireGuardRuntime {
            await runtime.stop()
        }
        if let bridge = loopbackBridge {
            await bridge.stop()
        }
        relayTransport?.disconnect()
        utunDevice?.close()
        wireGuardRuntime = nil
        loopbackBridge = nil
        relayTransport = nil
        utunDevice = nil
        routeManager = nil
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
        let device = try openUtun()
        var deviceCleanup = true
        defer {
            if deviceCleanup {
                device.close()
            }
        }

        let transport = try startRelayTransport(endpoint: nwRelayEndpoint)
        var transportCleanup = true
        defer {
            if transportCleanup {
                transport.disconnect()
            }
        }

        let bridge: LoopbackBindBridge
        do {
            bridge = try LoopbackBindBridge()
        } catch {
            throw daemonError(
                code: .runtimeStartFailure,
                message: "loopback bridge init failed: \(error.localizedDescription)"
            )
        }
        var bridgeCleanup = true
        defer {
            if bridgeCleanup {
                Task { await bridge.stop() }
            }
        }
        do {
            try await bridge.start(relay: transport)
        } catch {
            throw daemonError(
                code: .runtimeStartFailure,
                message: "loopback bridge start failed: \(error.localizedDescription)"
            )
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
        let routes = try installRoutes(plan: plan)

        deviceCleanup = false
        transportCleanup = false
        bridgeCleanup = false
        runtimeCleanup = false
        return TunnelComponents(
            device: device,
            transport: transport,
            bindBridge: bridge,
            runtime: runtime,
            routes: routes,
            parsedConfig: parsedConfig,
            relayEndpoint: relayEndpoint,
            plan: plan
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

    private func installRoutes(plan: RoutePlan) throws -> RouteManager {
        let manager = RouteManager()
        do {
            try manager.install(prefixes: plan.prefixes, onInterface: plan.interfaceName)
        } catch {
            throw daemonError(
                code: .runtimeStartFailure,
                message: "route install failed: \(error.localizedDescription)"
            )
        }
        return manager
    }

    private func commit(components: TunnelComponents) {
        utunDevice = components.device
        relayTransport = components.transport
        loopbackBridge = components.bindBridge
        wireGuardRuntime = components.runtime
        routeManager = components.routes
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

    private func openUtun() throws -> UtunDevice {
        do {
            return try UtunDevice()
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

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
        relayTransport?.disconnect()
        utunDevice?.close()
        wireGuardRuntime = nil
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

        wireBindBridgeStub(transport: transport)

        let runtime = try await startWireGuardRuntime(
            parsedConfig: parsedConfig,
            utunFd: device.fileDescriptor
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
        runtimeCleanup = false
        return TunnelComponents(
            device: device,
            transport: transport,
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
        utunFd: Int32
    ) async throws -> WireGuardRuntime {
        let uapi = parsedConfig.uapiConfig()
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

    private func wireBindBridgeStub(transport: RelayTransport) {
        // Bind bridge gap, tracked separately. wireguard-go's bundled api-apple.go pins the
        // bind to conn.NewStdNetBind(), which opens its own UDP socket and sends WireGuard
        // datagrams out the host's default route. RelayTransport receives have no path into
        // the device, and device sends never reach RelayTransport. Bridging the two ends
        // requires either forking WireGuardKitGo to accept a custom conn.Bind (preferred) or
        // running a localhost UDP loopback that the device's bind talks to and RelayTransport
        // pumps. Neither is in scope for this commit. The sink below is reserved for the
        // moment that bridge lands; until then incoming relay datagrams are dropped.
        transport.onReceive = { _ in
            // pending bind bridge; see comment above
        }
        assertBindBridgeNotForced()
    }

    private func assertBindBridgeNotForced() {
        #if DEBUG
            let env = ProcessInfo.processInfo.environment
            if env["CELLTUNNELD_FORCE_BIND_BRIDGE"] != nil {
                fatalError(
                    "wireguard-go bind bridge is not implemented; see DaemonState+Tunnel"
                )
            }
        #endif
    }
}

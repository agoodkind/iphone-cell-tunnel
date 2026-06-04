//
//  SimulatorRelayBackend.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-02.
//  Copyright © 2026, all rights reserved.
//

#if !targetEnvironment(macCatalyst)
    import CellTunnelCore
    import CellTunnelLog
    import CellTunnelRelay
    import Foundation

    private let logger = CellTunnelLog.logger(category: .relay)

    // MARK: - Constants

    private let relayStoppedStateText = "Stopped"

    // MARK: - SimulatorRelayBackend

    /// Hosts the real relay runtime in-process for the iOS Simulator, where the
    /// Network Extension packet tunnel has no launchable `nehelper` to start it.
    /// `PhoneRelayBackend` delegates here in the simulator. The runtime is the same
    /// engine the on-device packet tunnel hosts, so the simulator exercises the real
    /// control link, discovery, forwarder, and status path; only the background
    /// tunnel host is absent, which a foreground app does not need. It is the
    /// simulator composition root: it builds the host-network graph, where each
    /// connection egresses over the host network instead of a pinned interface.
    @MainActor
    final class SimulatorRelayBackend: RelayControlBackend {
        private let runtime = RelayRuntime(composition: .hostNetwork())

        // MARK: - Lifecycle

        func start() async {
            await Task.yield()
            logger.notice("simulator relay backend starting in-process relay runtime")
            runtime.start()
        }

        func stop() async {
            await Task.yield()
            logger.notice("simulator relay backend stopping in-process relay runtime")
            runtime.stop()
        }

        // MARK: - Sampling

        func sample() async -> RelayStatusSample? {
            await Task.yield()
            let snapshot = runtime.statusSnapshot()
            return RelayStatusSample(
                isRunning: snapshot.running,
                relayStateDescription: snapshot.relayState ?? relayStoppedStateText,
                connectedPeerName: snapshot.connectedPeerName,
                cellularPath: snapshot.cellularPath ?? CellularPathSnapshot(),
                counters: snapshot.phoneCounters ?? TunnelCounters(),
                lastError: snapshot.lastError,
                routeState: snapshot.routeState,
                peerState: snapshot.peerState,
                localLinkInterfaceName: snapshot.localLinkInterfaceName,
                relayHost: snapshot.relayHost,
                relayServerIPv4Address: snapshot.relayServerIPv4Address,
                relayServerIPv6Address: snapshot.relayServerIPv6Address
            )
        }

        // MARK: - Routing

        // Sends the routing choice to the agent over the runtime's real control
        // link, which installs or withdraws the program routes.
        func setRouting(enabled: Bool) async {
            await Task.yield()
            logger.notice(
                "simulator relay backend routing enabled=\(enabled, privacy: .public)")
            runtime.setRoutingEnabled(enabled)
        }
    }

#endif

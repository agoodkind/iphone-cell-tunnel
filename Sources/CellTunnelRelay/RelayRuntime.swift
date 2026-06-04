//
//  RelayRuntime.swift
//  CellTunnelRelay
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-03.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network
import Synchronization

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .relay)

// MARK: - RelayStatusState

/// The latest relay observations the forwarder and the control client push
/// through their callbacks, held behind a `Mutex` so the status path can read
/// them from any thread without hopping to the MainActor.
private struct RelayStatusState {
    var running = false
    var lastError: String?
    var connectedPeerName: String?
    var relayState = WireGuardDatagramRelayState.stopped.displayName
    /// Whether the agent has confirmed the program routes are installed. The agent
    /// owns the routes and reports this over the control link, so it is the truth
    /// the route state reports, not the local routing intent.
    var routeInstalled = false
    /// The WireGuard server endpoint the agent sent over the control link, reported
    /// as the relay's public address since device traffic egresses through it.
    var serverEndpoint: RelayEndpoint?
    /// The carrying link's interface, reported as the connected-via transport.
    var localLinkInterfaceName: String?
}

// MARK: - RelayRuntime

/// The iPhone relay engine, independent of its host. It owns the data plane
/// forwarder, the control link to the agent, the discovery probe, the cellular
/// path observer, and the status snapshot the UI reads. Two hosts drive the same
/// engine: the Network Extension packet tunnel hosts it on device to keep it
/// alive in the background, and the app hosts it in-process in the simulator,
/// where the Network Extension has no launchable `nehelper`. The host owns the
/// tun and the lifecycle callbacks; this owns the relay.
///
/// `@unchecked Sendable`: each stored member confines its own state to its queue
/// or behind the `Mutex`, and the `@MainActor` control client is reached only
/// through `Task { @MainActor }`.
public final class RelayRuntime: @unchecked Sendable {
    private let forwarder: PhoneRelayForwarder
    private let control: RelayControlChannel
    private let cellular: CellularPathObserving
    private let probe: RelayDiscovering
    private let statusState = Mutex(RelayStatusState())

    public init(composition: RelayComposition) {
        forwarder = PhoneRelayForwarder(interfaceBinder: composition.binder)
        control = composition.control
        cellular = composition.cellular
        probe = composition.probe
    }

    // MARK: - Lifecycle

    /// Brings up the relay: the cellular path observer, the forwarder and its
    /// status callbacks, the discovery probe that feeds the forwarder, and the
    /// control client that dials the agent for the WireGuard server endpoint.
    public func start() {
        cellular.start()
        configureForwarderCallbacks()
        forwarder.start()
        configureTransportSelection()
        startControlClient()
        statusState.withLock { $0.running = true }
        logger.notice("relay runtime started")
    }

    /// Tears the relay down and resets the status to stopped.
    public func stop() {
        let client = self.control
        Task { @MainActor in client.stop() }
        probe.stop()
        forwarder.stop()
        cellular.stop()
        statusState.withLock { state in
            state.running = false
            state.connectedPeerName = nil
            state.relayState = WireGuardDatagramRelayState.stopped.displayName
            state.routeInstalled = false
        }
        logger.notice("relay runtime torn down")
    }

    // MARK: - Control

    /// Pushes the routing choice to the agent over the control link, which installs
    /// or withdraws the program routes. The reported route state is not set here; it
    /// follows the agent's confirmation over the control link, so the UI never shows
    /// routing the agent has not installed. Off is passthrough, on is routing.
    public func setRoutingEnabled(_ enabled: Bool) {
        let client = control
        Task { @MainActor in client.sendRoutingEnabled(enabled) }
        logger.notice("relay runtime routing requested enabled=\(enabled, privacy: .public)")
    }

    // MARK: - Status

    /// One status reading assembled from the live relay observations, the cellular
    /// path, and the forwarder metrics.
    public func statusSnapshot() -> TunnelDaemonStatusSnapshot {
        let state = statusState.withLock { $0 }
        return TunnelDaemonStatusSnapshot(
            running: state.running,
            routeState: state.routeInstalled ? .installed : .notInstalled,
            peerState: state.running ? .relaySelected : .notSelected,
            lastError: state.lastError,
            phoneCounters: forwarder.metrics.snapshot(),
            cellularPath: cellular.snapshot,
            connectedPeerName: state.connectedPeerName,
            relayState: state.relayState,
            localLinkInterfaceName: state.localLinkInterfaceName,
            relayPublicIPv4Address: relayHost(state.serverEndpoint, family: .ipv4),
            relayPublicIPv6Address: relayHost(state.serverEndpoint, family: .ipv6)
        )
    }

    // MARK: - Wiring

    private func configureForwarderCallbacks() {
        forwarder.onStateChange = { [weak self] state in
            self?.statusState.withLock { $0.relayState = state.displayName }
            logger.notice("phone relay state changed state=\(state.rawValue, privacy: .public)")
        }
        forwarder.onError = { [weak self] message in
            self?.statusState.withLock { $0.lastError = message }
            logger.error("phone relay reported error=\(message, privacy: .public)")
        }
        forwarder.onPeerChange = { [weak self] name in
            self?.statusState.withLock { $0.connectedPeerName = name }
            logger.notice("phone relay peer changed peer=\(name ?? "none", privacy: .public)")
        }
        forwarder.onEgressInterfaceChange = { [weak self] name in
            self?.statusState.withLock { $0.localLinkInterfaceName = name }
            logger.notice(
                "phone relay egress interface changed interface=\(name ?? "none", privacy: .public)"
            )
        }
    }

    private func configureTransportSelection() {
        let relayForwarder = self.forwarder
        probe.configure { interfaces in
            relayForwarder.reconcileLinks(interfaces)
        }
        probe.start()
    }

    // The status closure borrows the non-copyable `statusState` Mutex through a
    // weak self instead of a hoisted local.
    private func startControlClient() {
        let client = self.control
        let relayForwarder = self.forwarder
        let observer = self.cellular
        Task { @MainActor [weak self] in
            client.configure(
                onSetServerEndpoint: { [weak self] endpoint in
                    relayForwarder.setServerEndpoint(endpoint)
                    self?.statusState.withLock { $0.serverEndpoint = endpoint }
                },
                onConnectionDropped: { [weak self] in
                    relayForwarder.resetLinks()
                    // The control link dropped, so any installed routes no longer
                    // hold; report not-installed until the agent reconfirms.
                    self?.statusState.withLock { $0.routeInstalled = false }
                },
                onRouteState: { [weak self] installed in
                    self?.statusState.withLock { $0.routeInstalled = installed }
                },
                statusProvider: {
                    let lastError = self.flatMap { runtime in
                        runtime.statusState.withLock { $0.lastError }
                    }
                    let cellularPath = observer.snapshot
                    return RelayControlMessage.Status(
                        hasCellularPath: cellularPath.isSatisfied,
                        cellularInterface: cellularPath.interfaceName,
                        lastError: lastError,
                        counters: relayForwarder.metrics.snapshot()
                    )
                }
            )
            client.start()
        }
    }

    // Reports the WireGuard server endpoint host for the requested family, the
    // relay's public identity that device traffic egresses through.
    private func relayHost(_ endpoint: RelayEndpoint?, family: RelayAddressFamily) -> String? {
        guard let endpoint, !endpoint.host.isEmpty, endpoint.addressFamily == family else {
            return nil
        }
        return endpoint.host
    }
}

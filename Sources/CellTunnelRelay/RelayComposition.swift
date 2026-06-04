//
//  RelayComposition.swift
//  CellTunnelRelay
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-03.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .relay)

// MARK: - RelayControlChannel

/// The control link to the Mac agent. It dials the agent, receives the WireGuard
/// server endpoint, reports a dropped connection, and answers status pushes.
/// `RelayRuntime` reaches it through this protocol so a test can drive the engine
/// with a fake channel. The handlers are passed to `configure` rather than set as
/// properties, so the protocol need not be class-bound.
@MainActor
protocol RelayControlChannel: Sendable {
    func configure(
        onSetServerEndpoint: @escaping @MainActor (RelayEndpoint) -> Void,
        onConnectionDropped: @escaping @MainActor () -> Void,
        onRouteState: @escaping @MainActor (Bool) -> Void,
        statusProvider: @escaping @MainActor () -> RelayControlMessage.Status
    )
    func start()
    func stop()
    func sendRoutingEnabled(_ enabled: Bool)
}

// MARK: - PhoneControlClient

extension PhoneControlClient: RelayControlChannel {
    func configure(
        onSetServerEndpoint: @escaping @MainActor (RelayEndpoint) -> Void,
        onConnectionDropped: @escaping @MainActor () -> Void,
        onRouteState: @escaping @MainActor (Bool) -> Void,
        statusProvider: @escaping @MainActor () -> RelayControlMessage.Status
    ) {
        self.onSetServerEndpoint = onSetServerEndpoint
        self.onConnectionDropped = onConnectionDropped
        self.onRouteState = onRouteState
        self.statusProvider = statusProvider
    }
}

// MARK: - RelayDiscovering

/// The discovery probe that reports which interfaces the Mac agent is reachable
/// on. `RelayRuntime` feeds its results to the forwarder through this protocol.
protocol RelayDiscovering: Sendable {
    func configure(onDiscover: @escaping @Sendable ([RelayMacInterface]) -> Void)
    func start()
    func stop()
}

// MARK: - RelayPathProbe

extension RelayPathProbe: RelayDiscovering {
    func configure(onDiscover: @escaping @Sendable ([RelayMacInterface]) -> Void) {
        self.onDiscover = onDiscover
    }
}

// MARK: - CellularPathObserving

/// The cellular path observer that holds the latest cellular `NWPath` snapshot
/// for status reporting. `RelayRuntime` reads its snapshot through this protocol.
protocol CellularPathObserving: Sendable {
    var snapshot: CellularPathSnapshot { get }

    func start()
    func stop()
}

// MARK: - CellularPathObserver

extension CellularPathObserver: CellularPathObserving {}

// MARK: - RelayComposition

/// The bundle of relay collaborators a host hands to the engine. Each host builds
/// the one preset that matches where it runs, so the engine owns no concrete
/// collaborator and reads no build target.
public struct RelayComposition {
    let binder: RelayInterfaceBinder
    let control: RelayControlChannel
    let probe: RelayDiscovering
    let cellular: CellularPathObserving

    /// The on-device graph: pin each connection to its physical interface.
    public static func pinned() -> RelayComposition {
        logger.notice("relay composition built mode=\("pinned", privacy: .public)")
        return RelayComposition(
            binder: PinnedInterfaceBinder(),
            control: PhoneControlClient(),
            probe: RelayPathProbe(),
            cellular: CellularPathObserver(requiredInterfaceType: .cellular)
        )
    }

    /// The in-process simulator graph: reach every peer over the host network.
    public static func hostNetwork() -> RelayComposition {
        logger.notice("relay composition built mode=\("host-network", privacy: .public)")
        return RelayComposition(
            binder: HostNetworkInterfaceBinder(),
            control: PhoneControlClient(),
            probe: RelayPathProbe(),
            cellular: CellularPathObserver(requiredInterfaceType: nil)
        )
    }
}

//
//  RelayInterfaceBinder.swift
//  CellTunnelRelay
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-03.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Network

// MARK: - RelayInterfaceBinder

/// Decides how a relay connection attaches to the network before it dials. The
/// host injects one implementation, so the data plane configures each connection
/// through this object instead of reading the build target.
protocol RelayInterfaceBinder: Sendable {
    /// A short label naming where the relay egresses, logged once when the
    /// cellular socket starts.
    var egressDescription: String { get }

    /// Configures the parameters for the socket that dials the WireGuard server.
    func configureServerParameters(_ parameters: NWParameters)

    /// Configures the parameters for one link that dials a discovered Mac
    /// interface.
    func configureLinkParameters(_ parameters: NWParameters, for interface: RelayMacInterface)
}

// MARK: - PinnedInterfaceBinder

/// Pins each connection to its physical interface: the cellular radio for the
/// server socket, and the discovered interface for each Mac link. This is the
/// on-device behavior, where each interface is a distinct physical path.
struct PinnedInterfaceBinder: RelayInterfaceBinder {
    let egressDescription = "pinned to physical interface"

    func configureServerParameters(_ parameters: NWParameters) {
        parameters.requiredInterfaceType = .cellular
    }

    func configureLinkParameters(_ parameters: NWParameters, for interface: RelayMacInterface) {
        parameters.requiredInterface = interface.interface
    }
}

// MARK: - HostNetworkInterfaceBinder

/// Applies no interface pin, so both connections use the host's general network.
/// This is the in-process simulator behavior, where there is no cellular radio
/// and the agent runs on the same host, so a pinned physical interface never
/// reaches its peer.
struct HostNetworkInterfaceBinder: RelayInterfaceBinder {
    let egressDescription = "host network"

    func configureServerParameters(_: NWParameters) {
        // No pin: the simulator has no cellular radio, so the server socket
        // egresses over the host's general network.
    }

    func configureLinkParameters(_: NWParameters, for _: RelayMacInterface) {
        // No pin: the agent is on the same host, reached over the host network
        // rather than the discovered physical interface.
    }
}

//
//  AgentRelayBridge+Links.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-31.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .daemon)

// MARK: - Phone link set and carrying selection

/// The multi-link half of the relay bridge: the set of phone links and the
/// chooser that selects which one the upload path carries on. A link is admitted
/// on its first received datagram and removed only when its connection errors.
/// Every method runs only on `AgentRelayBridge.queue`.
extension AgentRelayBridge {
    // MARK: - Membership

    /// Adds or replaces the phone link for the interface a connection arrived on.
    /// A redial on the same interface replaces the old connection. The first link
    /// installs routes; the carrying link is recomputed every time the set changes.
    func addPhoneLink(for connection: NWConnection) {
        let resolved = phoneInterface(for: connection)
        let wasEmpty = phoneLinks.isEmpty
        if let existing = phoneLinks[resolved.name], existing.connection !== connection {
            existing.connection.cancel()
        }
        phoneLinks[resolved.name] = AgentPhoneLink(
            interfaceName: resolved.name,
            linkClass: resolved.linkClass,
            connection: connection
        )
        logger.notice(
            """
            agent relay bridge adopted phone link interface=\(resolved.name, privacy: .public) \
            class=\(resolved.linkClass.rawValue, privacy: .public) \
            links=\(self.phoneLinks.count, privacy: .public)
            """
        )
        recomputeEgress()
        if wasEmpty {
            onPhoneConnected?()
        }
    }

    /// Removes the phone link a cancelled or failed connection belonged to. The
    /// last link dropping withdraws routes.
    func removePhoneLink(for connection: NWConnection) {
        guard let name = interfaceName(of: connection) else {
            return
        }
        phoneLinks.removeValue(forKey: name)
        logger.notice(
            """
            agent relay bridge dropped phone link interface=\(name, privacy: .public) \
            links=\(self.phoneLinks.count, privacy: .public)
            """
        )
        recomputeEgress()
        if phoneLinks.isEmpty {
            onPhoneDisconnected?()
        }
    }

    /// Admits a phone link on the first datagram seen on its connection (the
    /// iPhone's adoption prime). Later datagrams find the link already present and
    /// do nothing here.
    func notePhoneActivity(on connection: NWConnection) {
        if interfaceName(of: connection) != nil {
            return
        }
        addPhoneLink(for: connection)
    }

    private func interfaceName(of connection: NWConnection) -> String? {
        for (name, link) in phoneLinks where link.connection === connection {
            return name
        }
        return nil
    }

    // MARK: - Carrying selection

    /// Recomputes the cached carrying pointer from the chooser off the packet path.
    /// The upload path reads one pointer per datagram; it is recomputed here, on a
    /// link being admitted or removed. The agent has no override yet, so it uses
    /// the score order, the same order the iPhone uses, so both ends carry on the
    /// same link.
    func recomputeEgress() {
        let openLinks = phoneLinks.values.map { link in
            RelayLinkSnapshot(interfaceName: link.interfaceName, linkClass: link.linkClass)
        }
        let chosen = RelayLinkPolicy.chooseCarrying(preferred: nil, openLinks: Array(openLinks))
        if chosen != egressInterfaceName {
            logger.notice(
                "agent relay bridge carrying link interface=\(chosen ?? "none", privacy: .public)"
            )
        }
        egressInterfaceName = chosen
        egressConnection = chosen.flatMap { phoneLinks[$0]?.connection }
    }

    // MARK: - Interface derivation

    /// Resolves the Mac-facing interface and link class a connection runs over.
    /// The connection's path names the interface and its type; a link-local
    /// endpoint zone is the fallback when the path has no usable interface.
    private func phoneInterface(
        for connection: NWConnection
    ) -> (name: String, linkClass: RelayLinkClass) {
        if let interface = connection.currentPath?.availableInterfaces.first(where: { iface in
            iface.type != .loopback
        }) {
            return (interface.name, Self.linkClass(for: interface))
        }
        if let zone = Self.zoneName(from: connection.endpoint) {
            return (zone, Self.linkClass(forName: zone))
        }
        let fallback = String(describing: connection.endpoint)
        return (fallback, Self.linkClass(forName: fallback))
    }

    private static func linkClass(for interface: NWInterface) -> RelayLinkClass {
        switch interface.type {
        case .wiredEthernet:
            return .wired
        case .wifi:
            return .wifiLan
        case .cellular:
            return .cellular
        case .loopback:
            return .loopback
        case .other:
            // USB CDC-NCM Ethernet surfaces as `.other`; only AWDL is the slow
            // peer-to-peer path, so a non-AWDL other interface is a fast link.
            return interface.name.hasPrefix("awdl") ? .peerToPeer : .wired
        @unknown default:
            return .other
        }
    }

    private static func linkClass(forName name: String) -> RelayLinkClass {
        if name.hasPrefix("awdl") {
            return .peerToPeer
        }
        return .wired
    }

    private static func zoneName(from endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else {
            return nil
        }
        let description = "\(host)"
        guard let percent = description.firstIndex(of: "%") else {
            return nil
        }
        return String(description[description.index(after: percent)...])
    }
}

//
//  AgentRelayBridge+Links.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-31.
//  Copyright © 2026
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .daemon)
private let nanosecondsPerMillisecond = 1_000_000

// MARK: - Phone link set, heartbeat, carrying selection

/// The multi-link half of the relay bridge: the set of phone links, the per-link
/// keepalive that keeps each link's freshness current, and the policy that
/// selects which link the upload path carries on. A link is removed only when its
/// connection errors. Every method runs only on `AgentRelayBridge.queue`.
extension AgentRelayBridge {
    // MARK: - Membership

    /// Adds or replaces the phone link for the interface a ready connection
    /// arrived on. A redial on the same interface replaces the old connection.
    /// The first live link installs routes; the egress is recomputed every time
    /// the set changes.
    func addPhoneLink(for connection: NWConnection) {
        let resolved = phoneInterface(for: connection)
        let wasEmpty = phoneLinks.isEmpty
        if let existing = phoneLinks[resolved.name], existing.connection !== connection {
            existing.connection.cancel()
        }
        phoneLinks[resolved.name] = AgentPhoneLink(
            interfaceName: resolved.name,
            linkClass: resolved.linkClass,
            connection: connection,
            lastHeardMilliseconds: nowMilliseconds()
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

    /// Records inbound activity on a phone connection. The first datagram admits
    /// the link, reading the interface from the now-populated path; every later
    /// datagram refreshes its last-heard time, so a link carrying only heartbeats
    /// is not declared dead.
    func notePhoneActivity(on connection: NWConnection) {
        if let name = interfaceName(of: connection) {
            phoneLinks[name]?.lastHeardMilliseconds = nowMilliseconds()
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

    // MARK: - Maintenance: heartbeat and carrying refresh

    /// Starts the single repeating timer that, each tick, sends an empty keepalive
    /// on every phone link and recomputes the carrying link from current
    /// freshness. The tick never closes a link; a link closes only when its
    /// connection errors.
    func startMaintenanceTimer() {
        maintenanceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = RelayTransportPolicy.heartbeatIntervalMilliseconds
        timer.schedule(
            deadline: .now() + .milliseconds(interval),
            repeating: .milliseconds(interval)
        )
        timer.setEventHandler { @Sendable [weak self] in
            self?.maintenanceTick()
        }
        timer.resume()
        maintenanceTimer = timer
        logger.notice(
            "agent relay bridge maintenance armed intervalMs=\(interval, privacy: .public)"
        )
    }

    private func maintenanceTick() {
        sendHeartbeats()
        recomputeEgress()
    }

    private func sendHeartbeats() {
        guard !phoneLinks.isEmpty else {
            return
        }
        if !didLogHeartbeat {
            didLogHeartbeat = true
            logger.notice(
                "agent relay bridge heartbeat send path active links=\(self.phoneLinks.count, privacy: .public)"
            )
        }
        for link in phoneLinks.values {
            link.connection.send(
                content: Data(),
                completion: .contentProcessed { _ in
                    // Best-effort keepalive. A genuinely gone path surfaces as a
                    // connection error, which closes the link; this send does not.
                }
            )
        }
    }

    // MARK: - Egress selection

    /// Recomputes the cached carrying pointer from the policy off the packet path.
    /// The upload path reads one pointer per datagram; it is recomputed here, on
    /// each tick and on a membership change, from each link's freshness. Both ends
    /// run the same policy over the same preference, so the agent carries upload on
    /// the link the iPhone carries download on. The carrying link is empty only
    /// when no link is open.
    func recomputeEgress() {
        let now = nowMilliseconds()
        let snapshots = phoneLinks.values.map { link in
            RelayLinkSnapshot(
                interfaceName: link.interfaceName,
                linkClass: link.linkClass,
                silenceMilliseconds: now - link.lastHeardMilliseconds
            )
        }
        let plan = RelayLinkPolicy.plan(for: Array(snapshots))
        guard let egressName = plan.egressInterfaceName,
            let link = phoneLinks[egressName]
        else {
            egressConnection = nil
            return
        }
        if egressConnection !== link.connection {
            logger.notice(
                "agent relay bridge carrying link interface=\(egressName, privacy: .public)"
            )
        }
        egressConnection = link.connection
    }

    // MARK: - Interface derivation

    /// Resolves the Mac-facing interface and link class a connection runs over.
    /// The ready connection's path names the interface and its type; a link-local
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

    // MARK: - Time

    func nowMilliseconds() -> Int {
        Int(DispatchTime.now().uptimeNanoseconds / UInt64(nanosecondsPerMillisecond))
    }
}

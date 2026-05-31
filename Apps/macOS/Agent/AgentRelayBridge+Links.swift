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

// MARK: - Phone link set, heartbeat, liveness, egress

/// The multi-link half of the relay bridge: the set of warm phone links, the
/// per-link heartbeat that keeps a standby link's liveness fresh, the sweep that
/// reaps a dead link, and the policy that selects which link the upload path
/// egresses on. Every method runs only on `AgentRelayBridge.queue`.
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

    // MARK: - Maintenance: heartbeat and liveness sweep

    /// Starts the single repeating timer that, each tick, sends an empty
    /// heartbeat on every phone link and reaps any link that missed its class
    /// deadline. One timer covers both so the bridge has no per-link timer churn.
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
        sweepDeadLinks()
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
                    // Best-effort heartbeat: a send error is surfaced by the link
                    // missing its liveness deadline, which the sweep reaps.
                }
            )
        }
    }

    private func sweepDeadLinks() {
        let now = nowMilliseconds()
        let dead = phoneLinks.values.filter { link in
            let liveness = RelayLinkLiveness(
                linkClass: link.linkClass,
                lastHeardMilliseconds: link.lastHeardMilliseconds
            )
            return !liveness.isAlive(atMilliseconds: now)
        }
        guard !dead.isEmpty else {
            return
        }
        for link in dead {
            logger.notice(
                """
                agent relay bridge reaping dead link interface=\(link.interfaceName, privacy: .public) \
                class=\(link.linkClass.rawValue, privacy: .public)
                """
            )
            link.connection.cancel()
            phoneLinks.removeValue(forKey: link.interfaceName)
        }
        recomputeEgress()
        if phoneLinks.isEmpty {
            onPhoneDisconnected?()
        }
    }

    // MARK: - Egress selection

    /// Recomputes the cached egress pointer from the shared policy. The upload
    /// path reads one pointer per datagram; it is recomputed only here, when the
    /// link set or liveness changes. Both ends run the same policy over the same
    /// class ranking, so the agent egresses upload on the link the iPhone
    /// egresses download on.
    func recomputeEgress() {
        let now = nowMilliseconds()
        let snapshots = phoneLinks.values.map { link in
            let liveness = RelayLinkLiveness(
                linkClass: link.linkClass,
                lastHeardMilliseconds: link.lastHeardMilliseconds
            )
            return RelayLinkSnapshot(
                interfaceName: link.interfaceName,
                linkClass: link.linkClass,
                isLive: liveness.isAlive(atMilliseconds: now)
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
                "agent relay bridge egress link interface=\(egressName, privacy: .public)"
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

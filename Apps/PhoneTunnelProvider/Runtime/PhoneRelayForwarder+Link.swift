//
//  PhoneRelayForwarder+Link.swift
//  CellTunnelPhoneTunnel
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .relay)
private let nanosecondsPerMillisecond = 1_000_000

// MARK: - Mac-facing links: dial, prime, heartbeat, liveness, egress

/// Keeps one warm link per reachable interface and selects the egress with the
/// shared policy. The probe reports the interface set; this surface dials each
/// new interface pinned to it, primes it so the agent adopts it, heartbeats every
/// link to keep its liveness fresh, reaps a link that errors or misses its class
/// deadline, and recomputes the cached egress pointer whenever the set or its
/// liveness changes. Every method runs only on `PhoneRelayForwarder.queue`.
extension PhoneRelayForwarder {
    // MARK: - Reconcile

    func reconcileOnQueue(_ interfaces: [RelayMacInterface]) {
        let discovered = Set(interfaces.map(\.interfaceName))
        for interface in interfaces where macLinks[interface.interfaceName] == nil {
            dialLink(interface)
        }
        for name in macLinks.keys where !discovered.contains(name) {
            removeLink(interfaceName: name, reason: "no-longer-discovered")
        }
        recomputeEgress()
    }

    func resetLinksOnQueue() {
        guard !macLinks.isEmpty else {
            return
        }
        logger.notice("phone relay resetting all links on control drop")
        for link in macLinks.values {
            link.connection.cancel()
        }
        macLinks.removeAll()
        egressConnection = nil
        recomputeEgress()
    }

    // MARK: - Dial (one link per interface)

    private func dialLink(_ interface: RelayMacInterface) {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = interface.linkClass == .peerToPeer
        // Pin the connection to the discovered interface, so each interface
        // becomes its own link instead of the system collapsing them onto one.
        parameters.requiredInterface = interface.interface
        let connection = NWConnection(to: interface.endpoint, using: parameters)
        macLinks[interface.interfaceName] = PhoneMacLink(
            interfaceName: interface.interfaceName,
            linkClass: interface.linkClass,
            connection: connection,
            lastHeardMilliseconds: nowMilliseconds(),
            isReady: false
        )
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else {
                return
            }
            self?.handleLinkState(
                state, connection: connection, interfaceName: interface.interfaceName
            )
        }
        connection.start(queue: queue)
        logger.notice(
            """
            phone relay dialing link interface=\(interface.interfaceName, privacy: .public) \
            class=\(interface.linkClass.rawValue, privacy: .public)
            """
        )
    }

    private func handleLinkState(
        _ state: NWConnection.State, connection: NWConnection, interfaceName: String
    ) {
        guard isCurrentLink(connection, interfaceName: interfaceName) else {
            return
        }
        switch state {
        case .ready:
            macLinks[interfaceName]?.isReady = true
            macLinks[interfaceName]?.lastHeardMilliseconds = nowMilliseconds()
            logger.notice(
                "phone relay link ready interface=\(interfaceName, privacy: .public)"
            )
            primeLink(connection)
            receiveFromMac(on: connection, interfaceName: interfaceName)
            recomputeEgress()
        case .failed(let error):
            logger.error(
                """
                phone relay link failed interface=\(interfaceName, privacy: .public) \
                error=\(error.localizedDescription, privacy: .public)
                """
            )
            removeLink(interfaceName: interfaceName, reason: "failed")
        case .cancelled:
            removeLink(interfaceName: interfaceName, reason: "cancelled")
        default:
            break
        }
    }

    func handleLinkReceiveError(
        _ error: NWError, connection: NWConnection, interfaceName: String
    ) {
        logger.error(
            """
            phone relay link receive failed interface=\(interfaceName, privacy: .public) \
            error=\(error.localizedDescription, privacy: .public)
            """
        )
        connection.cancel()
        removeLink(interfaceName: interfaceName, reason: "receive-error")
    }

    // MARK: - Membership helpers

    func isCurrentLink(_ connection: NWConnection, interfaceName: String) -> Bool {
        macLinks[interfaceName]?.connection === connection
    }

    func stampLastHeard(interfaceName: String) {
        macLinks[interfaceName]?.lastHeardMilliseconds = nowMilliseconds()
    }

    private func removeLink(interfaceName: String, reason: String) {
        guard let link = macLinks.removeValue(forKey: interfaceName) else {
            return
        }
        link.connection.cancel()
        logger.notice(
            """
            phone relay dropped link interface=\(interfaceName, privacy: .public) \
            reason=\(reason, privacy: .public) links=\(self.macLinks.count, privacy: .public)
            """
        )
        recomputeEgress()
    }

    // A UDP NWConnection has no peer until the first datagram is sent, so the
    // agent cannot learn the iPhone source endpoint to route replies. Send one
    // empty datagram so the agent adopts this connection as a phone link. The
    // relay forwards only non-empty datagrams, so the prime never reaches
    // WireGuard.
    private func primeLink(_ connection: NWConnection) {
        connection.send(
            content: Data(),
            completion: .contentProcessed { error in
                guard let error else {
                    return
                }
                logger.error(
                    "phone relay link prime failed error=\(error.localizedDescription, privacy: .public)"
                )
            }
        )
    }

    // MARK: - Maintenance: heartbeat and liveness sweep

    func startMaintenanceTimer() {
        linkMaintenanceTimer?.cancel()
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
        linkMaintenanceTimer = timer
        logger.notice(
            "phone relay link maintenance armed intervalMs=\(interval, privacy: .public)"
        )
    }

    private func maintenanceTick() {
        sendHeartbeats()
        sweepDeadLinks()
    }

    private func sendHeartbeats() {
        let ready = macLinks.values.filter(\.isReady)
        guard !ready.isEmpty else {
            return
        }
        if didLogMacHeartbeat.compareExchange(
            expected: false, desired: true, ordering: .relaxed
        ).exchanged {
            logger.notice("phone relay heartbeat send path active")
        }
        for link in ready {
            link.connection.send(
                content: Data(),
                completion: .contentProcessed { _ in
                    // Best-effort heartbeat: a send error surfaces as the link
                    // missing its liveness deadline, which the sweep reaps.
                }
            )
        }
    }

    private func sweepDeadLinks() {
        let now = nowMilliseconds()
        let dead = macLinks.values.filter { link in
            guard link.isReady else {
                return false
            }
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
                phone relay reaping dead link interface=\(link.interfaceName, privacy: .public) \
                class=\(link.linkClass.rawValue, privacy: .public)
                """
            )
            link.connection.cancel()
            macLinks.removeValue(forKey: link.interfaceName)
        }
        recomputeEgress()
    }

    // MARK: - Egress selection

    /// Recomputes the cached egress pointer from the shared policy. The download
    /// path reads one pointer per datagram; it is recomputed only here, when the
    /// link set or liveness changes. A link counts as live only when its
    /// connection is ready and within its class deadline.
    func recomputeEgress() {
        let now = nowMilliseconds()
        let snapshots = macLinks.values.map { link in
            let liveness = RelayLinkLiveness(
                linkClass: link.linkClass,
                lastHeardMilliseconds: link.lastHeardMilliseconds
            )
            let isLive = link.isReady && liveness.isAlive(atMilliseconds: now)
            return RelayLinkSnapshot(
                interfaceName: link.interfaceName,
                linkClass: link.linkClass,
                isLive: isLive
            )
        }
        let plan = RelayLinkPolicy.plan(for: Array(snapshots))
        let egressLink = plan.egressInterfaceName.flatMap { macLinks[$0] }
        if let egressLink {
            if egressConnection !== egressLink.connection {
                logger.notice(
                    "phone relay egress link interface=\(egressLink.interfaceName, privacy: .public)"
                )
            }
            egressConnection = egressLink.connection
        } else {
            egressConnection = nil
        }
        updatePeerState(hasEgress: egressConnection != nil)
    }

    private func updatePeerState(hasEgress: Bool) {
        guard hasEgress != hasLivePeer else {
            return
        }
        hasLivePeer = hasEgress
        onPeerChange?(hasEgress ? "Mac" : nil)
    }

    // MARK: - Time

    func nowMilliseconds() -> Int {
        Int(DispatchTime.now().uptimeNanoseconds / UInt64(nanosecondsPerMillisecond))
    }
}

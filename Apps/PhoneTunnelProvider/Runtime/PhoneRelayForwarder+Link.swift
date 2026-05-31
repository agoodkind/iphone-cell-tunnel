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

/// Keeps the policy's set of links open and selects the carrying link with the
/// shared policy. The probe reports the interface set; this surface dials each
/// interface the policy keeps open, pinned to it, primes it so the agent adopts
/// it, sends a keepalive on every link, closes a link only when its connection
/// errors, and recomputes the cached carrying pointer off the packet path
/// whenever the set or its freshness changes. Every method runs only on
/// `PhoneRelayForwarder.queue`.
extension PhoneRelayForwarder {
    // MARK: - Reconcile

    func reconcileOnQueue(_ interfaces: [RelayMacInterface]) {
        let now = nowMilliseconds()
        let snapshots = interfaces.map { interface in
            let silence =
                macLinks[interface.interfaceName].map { link in
                    now - link.lastHeardMilliseconds
                } ?? 0
            return RelayLinkSnapshot(
                interfaceName: interface.interfaceName,
                linkClass: interface.linkClass,
                silenceMilliseconds: silence
            )
        }
        let keepWarm = Set(RelayLinkPolicy.plan(for: snapshots).keepWarm)
        for interface in interfaces {
            guard keepWarm.contains(interface.interfaceName) else {
                continue
            }
            guard macLinks[interface.interfaceName] == nil else {
                continue
            }
            dialLink(interface)
        }
        for name in Array(macLinks.keys) where !keepWarm.contains(name) {
            removeLink(interfaceName: name, reason: "not-kept-warm")
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

    // MARK: - Maintenance: heartbeat and carrying refresh

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
        recomputeEgress()
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
                    // Best-effort keepalive. A genuinely gone path surfaces as a
                    // connection error, which closes the link; this send does not.
                }
            )
        }
    }

    // MARK: - Egress selection

    /// Recomputes the cached carrying pointer from the policy off the packet path.
    /// The download path reads one pointer per datagram; it is recomputed here, on
    /// each tick and on a membership change, from each ready link's freshness. A
    /// link that is not ready yet is not a carrying candidate. The carrying link is
    /// empty only when no link is ready.
    func recomputeEgress() {
        let now = nowMilliseconds()
        let snapshots = macLinks.values.filter(\.isReady).map { link in
            RelayLinkSnapshot(
                interfaceName: link.interfaceName,
                linkClass: link.linkClass,
                silenceMilliseconds: now - link.lastHeardMilliseconds
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

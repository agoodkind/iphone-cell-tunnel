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

// MARK: - Mac-facing links: dial, prime, carry

/// Keeps one open link per discovered interface and chooses which one carries.
/// The probe reports the interface set; this surface dials each new interface
/// pinned to it and primes it once so the agent adopts it. A link is closed only
/// when its connection errors; a browse that stops listing an interface does not
/// close its link. The carrying link is the chooser's pick, recomputed on each
/// open or close, never on a timer. Every method runs only on
/// `PhoneRelayForwarder.queue`.
extension PhoneRelayForwarder {
    // MARK: - Reconcile (discovery only adds)

    func reconcileOnQueue(_ interfaces: [RelayMacInterface]) {
        for interface in interfaces where macLinks[interface.interfaceName] == nil {
            dialLink(interface)
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
        egressInterfaceName = nil
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
    // empty datagram so the agent adopts this connection as a link. The relay
    // forwards only non-empty datagrams, so the prime never reaches WireGuard.
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

    // MARK: - Carrying selection

    /// Recomputes the cached carrying pointer from the chooser off the packet path.
    /// The download path reads one pointer per datagram; it is recomputed here, on
    /// a link opening or closing or the override changing, never on a timer. Only
    /// ready links are carrying candidates.
    func recomputeEgress() {
        let openReady = macLinks.values
            .filter(\.isReady)
            .map { link in
                RelayLinkSnapshot(interfaceName: link.interfaceName, linkClass: link.linkClass)
            }
        let chosen = RelayLinkPolicy.chooseCarrying(
            preferred: preferredInterface, openLinks: Array(openReady)
        )
        if chosen != egressInterfaceName {
            logger.notice(
                "phone relay carrying link interface=\(chosen ?? "none", privacy: .public)"
            )
        }
        egressInterfaceName = chosen
        egressConnection = chosen.flatMap { macLinks[$0]?.connection }
        updatePeerState(hasEgress: egressConnection != nil)
    }

    private func updatePeerState(hasEgress: Bool) {
        guard hasEgress != hasLivePeer else {
            return
        }
        hasLivePeer = hasEgress
        onPeerChange?(hasEgress ? "Mac" : nil)
    }
}

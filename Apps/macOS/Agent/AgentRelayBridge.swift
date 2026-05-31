//
//  AgentRelayBridge.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .daemon)
private let relayDataServiceType = "_cellrelay._udp"

// MARK: - AgentPhoneLink

/// One warm link from the iPhone, keyed by the Mac-facing interface it arrived
/// on. The agent keeps one per interface at once so an abrupt loss of any link
/// fails over to another without a redial. `lastHeardMilliseconds` is refreshed
/// on every datagram, empty heartbeat or real data, and feeds the liveness check.
struct AgentPhoneLink {
    let interfaceName: String
    let linkClass: RelayLinkClass
    let connection: NWConnection
    var lastHeardMilliseconds: Int
}

// MARK: - AgentRelayBridge

/// Hosts the relay data plane in the agent, a normal process that receives
/// inbound from both peers over UDP. One listener binds the relay data port and
/// advertises the relay Bonjour service on every path, so the iPhone reaches it
/// over the wired USB link, Wi-Fi LAN, and AWDL at once. The Mac tunnel extension
/// dials it over loopback; the iPhone extension dials it once per interface, so
/// the bridge holds one Mac connection and a set of phone links keyed by
/// interface. Each datagram from the Mac goes out the egress phone link the
/// shared policy selects; each datagram from any phone link goes to the Mac. Each
/// send stays an independent UDP datagram with no added ordering or reliability;
/// WireGuard owns end-to-end integrity and dedupes any duplicate.
///
/// The `@unchecked Sendable` contract: every stored property is read and written
/// only on `queue`. All Network objects and timers start with `queue`, so their
/// callbacks fire on `queue`.
final class AgentRelayBridge: @unchecked Sendable {
    let queue = DispatchQueue(label: "io.goodkind.celltunnel.agent.relay")
    private var listener: NWListener?
    private var macConnection: NWConnection?

    // The warm phone links keyed by Mac-facing interface name, the cached egress
    // pointer the upload path reads per datagram, and the maintenance timer that
    // sends heartbeats and reaps dead links. All touched only on `queue`.
    var phoneLinks: [String: AgentPhoneLink] = [:]
    var egressConnection: NWConnection?
    var maintenanceTimer: DispatchSourceTimer?

    // Logs the heartbeat send path exactly once instead of per tick, so the
    // network-send boundary is logged without flooding the log every interval.
    var didLogHeartbeat = false

    /// Fired when the first phone link goes live and when the last one drops, so
    /// the agent tells the Mac extension to install or withdraw routes with the
    /// link set. Route gating is any-link-up: routes install on the 0-to-one
    /// transition and withdraw on the one-to-0 transition.
    var onPhoneConnected: (@Sendable () -> Void)?
    var onPhoneDisconnected: (@Sendable () -> Void)?

    // MARK: - Lifecycle

    func start(serviceName: String) {
        queue.async { [weak self] in
            self?.startOnQueue(serviceName: serviceName)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    private func startOnQueue(serviceName: String) {
        let port = resolvedRelayListenerPort()
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        // Advertise on every path, wired and peer-to-peer, so the relay service is
        // reachable over the USB link, Wi-Fi LAN, and AWDL. The iPhone dials one
        // link per interface; the agent keeps them all warm.
        parameters.includePeerToPeer = true

        let nwListener: NWListener
        do {
            nwListener = try NWListener(using: parameters, on: port)
        } catch {
            logger.error(
                """
                agent relay bridge listener create failed \
                details=\(String(describing: error), privacy: .public) \
                recovery=skip-bridge
                """
            )
            return
        }
        nwListener.service = NWListener.Service(name: serviceName, type: relayDataServiceType)
        nwListener.stateUpdateHandler = { state in
            applyRelayListenerState(state)
        }
        nwListener.newConnectionHandler = { [weak self] connection in
            self?.adopt(connection)
        }
        nwListener.start(queue: queue)
        listener = nwListener
        startMaintenanceTimer()
        logger.notice(
            """
            agent relay bridge starting service=\(relayDataServiceType, privacy: .public) \
            name=\(serviceName, privacy: .public) port=\(port.rawValue ?? 0, privacy: .public)
            """
        )
    }

    private func stopOnQueue() {
        macConnection?.cancel()
        macConnection = nil
        maintenanceTimer?.cancel()
        maintenanceTimer = nil
        for link in phoneLinks.values {
            link.connection.cancel()
        }
        phoneLinks.removeAll()
        egressConnection = nil
        listener?.cancel()
        listener = nil
        logger.notice("agent relay bridge stopped")
    }

    // MARK: - Connection adoption

    private func adopt(_ connection: NWConnection) {
        let isLoopback = Self.isLoopback(connection.endpoint)
        if isLoopback {
            macConnection?.cancel()
            macConnection = connection
            logger.notice(
                """
                agent relay bridge adopted mac connection \
                endpoint=\(String(describing: connection.endpoint), privacy: .public)
                """
            )
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else {
                return
            }
            self?.handle(state: state, connection: connection, isLoopback: isLoopback)
        }
        connection.start(queue: queue)
        receive(on: connection, fromMac: isLoopback)
    }

    private func handle(state: NWConnection.State, connection: NWConnection, isLoopback: Bool) {
        switch state {
        case .failed(let error):
            logger.error(
                """
                agent relay bridge connection failed mac=\(isLoopback, privacy: .public) \
                error=\(error.localizedDescription, privacy: .public)
                """
            )
            connection.cancel()
            clearIfCurrent(connection, isLoopback: isLoopback)
        case .cancelled:
            clearIfCurrent(connection, isLoopback: isLoopback)
        default:
            break
        }
    }

    private func clearIfCurrent(_ connection: NWConnection, isLoopback: Bool) {
        if isLoopback {
            if macConnection === connection {
                macConnection = nil
            }
        } else {
            removePhoneLink(for: connection)
        }
    }

    // MARK: - Datagram bridge

    private func receive(on connection: NWConnection, fromMac: Bool) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else {
                return
            }
            if let error {
                logger.error(
                    """
                    agent relay bridge receive failed mac=\(fromMac, privacy: .public) \
                    error=\(error.localizedDescription, privacy: .public)
                    """
                )
                connection.cancel()
                clearIfCurrent(connection, isLoopback: fromMac)
                return
            }
            if !fromMac {
                // The first datagram on a phone connection (the prime) admits the
                // link; every later datagram, empty heartbeat or real data,
                // refreshes its liveness so a quiet but working link is not reaped.
                notePhoneActivity(on: connection)
            }
            if let data, !data.isEmpty {
                forward(data, fromMac: fromMac)
            }
            receive(on: connection, fromMac: fromMac)
        }
    }

    private func forward(_ data: Data, fromMac: Bool) {
        let target = fromMac ? egressConnection : macConnection
        guard let target else {
            return
        }
        target.send(
            content: data,
            completion: .contentProcessed { error in
                guard let error else {
                    return
                }
                logger.error(
                    """
                    agent relay bridge send failed toMac=\(!fromMac, privacy: .public) \
                    error=\(error.localizedDescription, privacy: .public)
                    """
                )
            }
        )
    }

    // MARK: - Loopback classification

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else {
            return false
        }
        switch host {
        case .ipv4(let address):
            return address.isLoopback
        case .ipv6(let address):
            return address.isLoopback
        case .name(let name, _):
            return name == "localhost"
        @unknown default:
            return false
        }
    }
}

// MARK: - Listener state handling

/// Logs the relay bridge listener lifecycle so its bind and readiness are
/// visible in the log.
private func applyRelayListenerState(_ state: NWListener.State) {
    switch state {
    case .ready:
        logger.notice("agent relay bridge listener ready")
    case .failed(let error):
        logger.error(
            "agent relay bridge listener failed error=\(error.localizedDescription, privacy: .public)"
        )
    case .cancelled:
        logger.notice("agent relay bridge listener cancelled")
    default:
        break
    }
}

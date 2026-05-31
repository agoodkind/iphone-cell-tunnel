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

// MARK: - AgentRelayBridge

/// Hosts the relay data plane in the agent, a normal process that receives
/// inbound from both peers over UDP. One listener binds the relay data port and
/// advertises the relay Bonjour service so the iPhone resolves the working path.
/// Two parties dial it: the Mac tunnel extension over loopback, and the iPhone
/// extension over the local link. The bridge classifies each accepted connection
/// by remote host (loopback is the Mac, anything else is the iPhone) and forwards
/// every datagram from one side to the other. Each datagram stays an independent
/// UDP send with no added ordering or reliability; WireGuard owns end-to-end
/// integrity.
///
/// The `@unchecked Sendable` contract: every stored property is read and written
/// only on `queue`. All Network objects start with `.start(queue: queue)` so
/// their callbacks fire on `queue`.
final class AgentRelayBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.goodkind.celltunnel.agent.relay")
    private var listener: NWListener?
    private var macConnection: NWConnection?
    private var phoneConnection: NWConnection?

    /// Fired when the iPhone relay connection is adopted or dropped, so the agent
    /// can tell the Mac extension to install or withdraw routes with the link.
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
        phoneConnection?.cancel()
        phoneConnection = nil
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
        } else {
            phoneConnection?.cancel()
            phoneConnection = connection
            logger.notice(
                """
                agent relay bridge adopted phone connection \
                endpoint=\(String(describing: connection.endpoint), privacy: .public)
                """
            )
            onPhoneConnected?()
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
        if isLoopback, macConnection === connection {
            macConnection = nil
        } else if !isLoopback, phoneConnection === connection {
            phoneConnection = nil
            onPhoneDisconnected?()
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
            if let data, !data.isEmpty {
                forward(data, fromMac: fromMac)
            }
            receive(on: connection, fromMac: fromMac)
        }
    }

    private func forward(_ data: Data, fromMac: Bool) {
        let target = fromMac ? phoneConnection : macConnection
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

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network
import Synchronization

private let logger = CellTunnelLog.logger(category: .relay)
private let relayServiceType = "_cellrelay._udp"

/// Owns the entire iPhone relay data plane on one serial queue: the Mac-facing
/// NWListener and accepted connection, the cellular NWConnection to the
/// WireGuard server, the connecting/ready state machine with its pending
/// buffer, and the lock-free `RelayMetrics`. Every datagram in both directions
/// is received, wrapped, and forwarded on this one queue with no per-packet
/// actor hop, so throughput is not gated by the MainActor. The queue serializes
/// only code execution for race-free shared state; the datagrams stay
/// independent UDP sends with no added ordering or reliability. The cellular and
/// download halves live in `PhoneRelayForwarder+Cellular.swift`.
///
/// The `@unchecked Sendable` contract: every stored property is read and written
/// only on `queue`. All Network objects start with `.start(queue: queue)` so
/// their callbacks fire on `queue`, and the public API funnels through
/// `queue.async`. Lifecycle transitions are pushed to the MainActor UI through
/// the `@Sendable` callbacks; nothing on the per-packet path touches MainActor.
final class PhoneRelayForwarder: @unchecked Sendable {
    let metrics = RelayMetrics()

    let queue = DispatchQueue(label: "CellTunnelPhone.RelayPlane")
    var listener: NWListener?
    var macConnection: NWConnection?
    var cellularConnection: NWConnection?
    var endpointFamily = RelayAddressFamily.ipv4
    var state = WireGuardDatagramRelayState.stopped
    var pendingDatagrams: [WireGuardDatagram] = []
    var configuredEndpoint: RelayEndpoint?

    // Once-only flags so each boundary function logs context exactly once
    // (satisfying the boundary-log audit) instead of logging per datagram.
    let didLogMacReceive = Atomic<Bool>(false)
    let didLogMacSend = Atomic<Bool>(false)
    let didLogCellularReceive = Atomic<Bool>(false)
    let didLogCellularSend = Atomic<Bool>(false)

    var onStateChange: (@Sendable (WireGuardDatagramRelayState) -> Void)?
    var onError: (@Sendable (String) -> Void)?
    var onPeerChange: (@Sendable (String?) -> Void)?
    var onListenerReady: (@Sendable (UInt16?) -> Void)?

    // MARK: - Public API (MainActor callers funnel onto the relay queue)

    func startListener(port: NWEndpoint.Port, serviceName: String) {
        logger.notice(
            "phone relay forwarder listener requested service=\(relayServiceType, privacy: .public)"
        )
        queue.async { [weak self] in
            self?.startListenerOnQueue(port: port, serviceName: serviceName)
        }
    }

    func setServerEndpoint(_ endpoint: RelayEndpoint) {
        logger.notice(
            """
            phone relay forwarder server endpoint host=\(endpoint.host, privacy: .public) \
            port=\(endpoint.port, privacy: .public)
            """
        )
        queue.async { [weak self] in
            self?.applyEndpointOnQueue(endpoint)
        }
    }

    func stop() {
        logger.notice("phone relay forwarder stop requested")
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    // MARK: - Listener (queue-only)

    private func startListenerOnQueue(port: NWEndpoint.Port, serviceName: String) {
        do {
            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters, on: port)
            listener.service = NWListener.Service(name: serviceName, type: relayServiceType)
            listener.newConnectionHandler = { [weak self] connection in
                self?.adoptMacConnection(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            listener.start(queue: queue)
            self.listener = listener
            logger.notice(
                """
                phone relay listener started service=\(relayServiceType, privacy: .public) \
                name=\(serviceName, privacy: .public)
                """
            )
        } catch {
            logger.error(
                "phone relay listener failed error=\(error.localizedDescription, privacy: .public)"
            )
            onError?(error.localizedDescription)
            onListenerReady?(nil)
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            let port = listener?.port?.rawValue
            logger.notice("phone relay listener ready port=\(port ?? 0, privacy: .public)")
            onListenerReady?(port)
        case .failed(let error):
            logger.error(
                "phone relay listener state failed error=\(error.localizedDescription, privacy: .public)"
            )
            onError?(error.localizedDescription)
            onListenerReady?(nil)
        case .cancelled:
            logger.notice("phone relay listener cancelled")
            onListenerReady?(nil)
        default:
            logger.debug("phone relay listener state changed")
        }
    }

    // MARK: - Mac-facing connection (queue-only)

    private func adoptMacConnection(_ connection: NWConnection) {
        if let existing = macConnection, existing !== connection {
            logger.notice("phone relay replacing previous mac connection")
            existing.cancel()
        }
        macConnection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else {
                return
            }
            self?.handleMacConnectionState(state, connection: connection)
        }
        connection.start(queue: queue)
        onPeerChange?("Mac")
        logger.notice(
            "phone relay accepting mac connection endpoint=\(String(describing: connection.endpoint), privacy: .public)"
        )
        receiveFromMac(on: connection)
    }

    private func handleMacConnectionState(_ state: NWConnection.State, connection: NWConnection) {
        switch state {
        case .failed(let error):
            logger.error(
                "phone relay mac connection failed error=\(error.localizedDescription, privacy: .public)"
            )
            onError?(error.localizedDescription)
            connection.cancel()
            if macConnection === connection {
                macConnection = nil
                onPeerChange?(nil)
            }
        case .cancelled:
            if macConnection === connection {
                logger.notice("phone relay mac connection cancelled")
                macConnection = nil
                onPeerChange?(nil)
            }
        default:
            break
        }
    }

    private func handleMacReceiveError(_ error: NWError, connection: NWConnection) {
        logger.error(
            "phone relay mac receive failed error=\(error.localizedDescription, privacy: .public)"
        )
        onError?(error.localizedDescription)
        connection.cancel()
        if macConnection === connection {
            macConnection = nil
            onPeerChange?(nil)
        }
    }

    // MARK: - Upload hot path (Mac -> server), queue-only, no actor hop

    private func receiveFromMac(on connection: NWConnection) {
        if didLogMacReceive.compareExchange(
            expected: false, desired: true, ordering: .relaxed
        ).exchanged {
            logger.notice("phone relay mac receive loop armed")
        }
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else {
                return
            }
            if let error {
                handleMacReceiveError(error, connection: connection)
                return
            }
            if let data, !data.isEmpty {
                metrics.addBytesIn(UInt64(data.count))
                metrics.addDatagramsFromMac()
                adoptMacConnectionIfNeeded(connection)
                sendToServer(data)
            }
            receiveFromMac(on: connection)
        }
    }

    private func adoptMacConnectionIfNeeded(_ connection: NWConnection) {
        if macConnection !== connection {
            adoptMacConnection(connection)
        }
    }

    private func sendToServer(_ data: Data) {
        do {
            let datagram = try WireGuardDatagram(data: data, addressFamily: .ipv4)
            if state == .connecting {
                bufferPendingDatagram(datagram)
                return
            }
            guard state == .ready else {
                metrics.addDropped()
                logger.error(
                    "phone relay send rejected state=\(self.state.rawValue, privacy: .public)"
                )
                return
            }
            cellularSend(datagram)
        } catch {
            metrics.addDropped()
            logger.error(
                "phone relay datagram from mac rejected error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

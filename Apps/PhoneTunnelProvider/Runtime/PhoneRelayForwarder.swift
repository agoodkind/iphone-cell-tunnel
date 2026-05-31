import CellTunnelCore
import CellTunnelLog
import Foundation
import Network
import Synchronization

private let logger = CellTunnelLog.logger(category: .relay)
private let relayServiceType = "_cellrelay._udp"

/// Owns the entire iPhone relay data plane on one serial queue: the Mac-facing
/// NWConnection dialed to the agent, the cellular NWConnection to the WireGuard
/// server, the connecting/ready state machine with its pending buffer, and the
/// lock-free `RelayMetrics`. Every datagram in both directions is received,
/// wrapped, and forwarded on this one queue with no per-packet actor hop, so
/// throughput is not gated by the MainActor. The queue serializes only code
/// execution for race-free shared state; the datagrams stay independent UDP
/// sends with no added ordering or reliability. The cellular and download halves
/// live in `PhoneRelayForwarder+Cellular.swift`.
///
/// The `@unchecked Sendable` contract: every stored property is read and written
/// only on `queue`. All Network objects start with `.start(queue: queue)` so
/// their callbacks fire on `queue`, and the public API funnels through
/// `queue.async`. Lifecycle transitions are pushed to the MainActor UI through
/// the `@Sendable` callbacks; nothing on the per-packet path touches MainActor.
final class PhoneRelayForwarder: @unchecked Sendable {
    let metrics = RelayMetrics()

    let queue = DispatchQueue(label: "CellTunnelPhone.RelayPlane")
    var macBrowser: NWBrowser?
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

    // MARK: - Public API (MainActor callers funnel onto the relay queue)

    func start() {
        logger.notice("phone relay forwarder browse requested")
        queue.async { [weak self] in
            self?.startBrowseOnQueue()
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

    // MARK: - Mac-facing browse and connection (queue-only)

    private func startBrowseOnQueue() {
        macBrowser?.cancel()
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: relayServiceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: parameters)
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                logger.notice("phone relay browser ready")
            case .failed(let error):
                logger.error(
                    "phone relay browser failed error=\(error.localizedDescription, privacy: .public)"
                )
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                if case .service = result.endpoint {
                    self?.connectToMacOnQueue(endpoint: result.endpoint)
                    return
                }
            }
        }
        browser.start(queue: queue)
        macBrowser = browser
        logger.notice(
            "phone relay forwarder browsing service=\(relayServiceType, privacy: .public)"
        )
    }

    private func connectToMacOnQueue(endpoint: NWEndpoint) {
        guard macConnection == nil else {
            return
        }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: parameters)
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
            """
            phone relay dialing mac \
            endpoint=\(String(describing: connection.endpoint), privacy: .public)
            """
        )
        receiveFromMac(on: connection)
        primeMacConnection(connection)
    }

    // A UDP NWConnection has no peer until the first datagram is sent, so the
    // agent cannot learn the iPhone source endpoint to route replies. Send one
    // empty datagram on connect so the agent adopts this connection as the phone
    // side before any WireGuard handshake reply arrives.
    private func primeMacConnection(_ connection: NWConnection) {
        connection.send(
            content: Data(),
            completion: .contentProcessed { error in
                guard let error else {
                    return
                }
                logger.error(
                    "phone relay mac prime failed error=\(error.localizedDescription, privacy: .public)"
                )
            }
        )
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
                sendToServer(data)
            }
            receiveFromMac(on: connection)
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

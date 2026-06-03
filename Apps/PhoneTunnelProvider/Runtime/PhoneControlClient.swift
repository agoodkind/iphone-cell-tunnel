//
//  PhoneControlClient.swift
//  CellTunnelPhoneTunnel
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .relay)
private let statusPushIntervalSeconds: UInt64 = 5

// MARK: - PhoneControlClient

/// Runs the iPhone side of the control link by dialing the Mac. It browses for
/// the Mac control Bonjour service over the local link, connects to it, receives
/// the WireGuard server endpoint, applies it through `onSetServerEndpoint`,
/// acknowledges, and pushes periodic status snapshots back to the Mac. The Mac
/// hosts the listener; this dials out, which an iOS packet-tunnel extension is
/// permitted to do.
@MainActor
final class PhoneControlClient {
    typealias EndpointHandler = @MainActor (RelayEndpoint) -> Void
    typealias StatusProvider = @MainActor () -> RelayControlMessage.Status

    let queue = DispatchQueue(label: "io.goodkind.celltunnel.controlClient")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var statusTimer: DispatchSourceTimer?
    var redialTimer: DispatchSourceTimer?
    var isActive = false

    var onSetServerEndpoint: EndpointHandler?
    var statusProvider: StatusProvider?
    // Fired when the control connection drops, which is the reliable signal that
    // the agent died or restarted. The data plane dials over UDP and does not
    // surface a drop, so the provider uses this to reset the stale data link.
    var onConnectionDropped: (@MainActor () -> Void)?

    // MARK: - Lifecycle

    func start() {
        stop()
        isActive = true
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(
            type: relayControlServiceType,
            domain: nil
        )
        let nwBrowser = NWBrowser(for: descriptor, using: parameters)
        nwBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handle(browserState: state)
            }
        }
        nwBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                if case .service = result.endpoint {
                    let endpoint = result.endpoint
                    Task { @MainActor [weak self] in
                        self?.connectIfNeeded(to: endpoint)
                    }
                    return
                }
            }
        }
        nwBrowser.start(queue: queue)
        browser = nwBrowser
        logger.notice(
            "control client browsing service=\(relayControlServiceType, privacy: .public)"
        )
    }

    func stop() {
        isActive = false
        redialTimer?.cancel()
        redialTimer = nil
        statusTimer?.cancel()
        statusTimer = nil
        connection?.cancel()
        connection = nil
        browser?.cancel()
        browser = nil
        logger.notice("control client stopped")
    }

    // MARK: - Browse and dial

    private func handle(browserState state: NWBrowser.State) {
        switch state {
        case .ready:
            logger.notice("control client browser ready")
        case .failed(let error):
            logger.error(
                "control client browser failed error=\(error.localizedDescription, privacy: .public)"
            )
            scheduleReconnect()
        default:
            logger.debug("control client browser state changed")
        }
    }

    private func connectIfNeeded(to endpoint: NWEndpoint) {
        guard connection == nil else {
            return
        }
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        let framerOptions = RelayControlFramerSupport.framerOptions()
        parameters.defaultProtocolStack.applicationProtocols.insert(framerOptions, at: 0)

        let nwConnection = NWConnection(to: endpoint, using: parameters)
        connection = nwConnection
        nwConnection.stateUpdateHandler = { [weak self, weak nwConnection] state in
            Task { @MainActor [weak self, weak nwConnection] in
                guard let nwConnection else {
                    return
                }
                self?.handle(connectionState: state, connection: nwConnection)
            }
        }
        nwConnection.start(queue: queue)
        logger.notice(
            "control client dialing endpoint=\(String(describing: endpoint), privacy: .public)"
        )
    }

    private func handle(connectionState state: NWConnection.State, connection: NWConnection) {
        switch state {
        case .ready:
            logger.notice("control client connection ready")
            receive(on: connection)
            startStatusLoop()
        case .waiting(let error):
            logger.error(
                "control client connection waiting error=\(error.localizedDescription, privacy: .public)"
            )
        case .failed(let error):
            logger.error(
                "control client connection failed error=\(error.localizedDescription, privacy: .public)"
            )
            if self.connection === connection {
                self.connection = nil
            }
            connection.cancel()
            notifyConnectionDropped()
            scheduleReconnect()
        case .cancelled:
            if self.connection === connection {
                self.connection = nil
                logger.notice("control client connection cancelled")
            }
            notifyConnectionDropped()
            scheduleReconnect()
        default:
            break
        }
    }

    // Tells the provider the control link dropped so it can reset the stale data
    // link. Gated on `isActive` so an intentional `stop` does not trigger it.
    private func notifyConnectionDropped() {
        guard isActive else {
            return
        }
        onConnectionDropped?()
    }

    // MARK: - Receive and decode

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, isComplete, error in
            if let error {
                logger.error(
                    "control client receive failed error=\(error.localizedDescription, privacy: .public)"
                )
                Task { @MainActor [weak self, weak connection] in
                    guard let connection else {
                        return
                    }
                    if self?.connection === connection {
                        self?.connection = nil
                    }
                    connection.cancel()
                }
                return
            }

            if let data, !data.isEmpty {
                Task { @MainActor [weak self, weak connection] in
                    guard let connection else {
                        return
                    }
                    self?.handlePayload(data, connection: connection)
                }
            }

            guard !isComplete, let connection else {
                return
            }

            Task { @MainActor [weak self, weak connection] in
                guard let connection else {
                    return
                }
                self?.receive(on: connection)
            }
        }
    }

    private func handlePayload(_ payload: Data, connection: NWConnection) {
        let decoded: RelayControlMessage
        do {
            decoded = try RelayControlMessageCodec.decode(payload)
        } catch let RelayControlCodecError.unsupportedVersion(version) {
            logger.error(
                "control message rejected unsupportedVersion=\(version, privacy: .public)"
            )
            let failure = RelayControlMessage.Failure(
                code: "unsupported-version",
                message: "iPhone supports control wire version \(relayControlWireVersion)"
            )
            send(.error(failure), on: connection)
            return
        } catch {
            logger.error(
                "control message decode failed error=\(error.localizedDescription, privacy: .public)"
            )
            let failure = RelayControlMessage.Failure(
                code: "decode-failure",
                message: error.localizedDescription
            )
            send(.error(failure), on: connection)
            return
        }

        switch decoded {
        case .setServerEndpoint(let payload):
            logger.notice(
                """
                control received set-server-endpoint host=\(payload.endpoint.host, privacy: .public) \
                port=\(payload.endpoint.port, privacy: .public) \
                family=\(payload.endpoint.addressFamily.rawValue, privacy: .public)
                """
            )
            onSetServerEndpoint?(payload.endpoint)
            let ack = RelayControlMessage.Acknowledge(
                requestKind: "set-server-endpoint",
                detail: "endpoint accepted"
            )
            send(.acknowledge(ack), on: connection)
            sendStatusSnapshot(on: connection)
        case .acknowledge:
            logger.debug("control received unexpected acknowledge from peer")
        case .status:
            logger.debug("control received unexpected status from peer")
        case .error(let payload):
            logger.error(
                """
                control received error from peer code=\(payload.code, privacy: .public) \
                message=\(payload.message, privacy: .public)
                """
            )
        }
    }

    // MARK: - Send

    private func send(_ message: RelayControlMessage, on connection: NWConnection) {
        let payload: Data
        do {
            payload = try RelayControlMessageCodec.encode(message)
        } catch {
            logger.error(
                """
                control encode failed kind=\(message.kindLabel, privacy: .public) \
                error=\(error.localizedDescription, privacy: .public)
                """
            )
            return
        }
        let framerMessage = NWProtocolFramer.Message(definition: RelayControlFramer.definition)
        let context = NWConnection.ContentContext(
            identifier: message.kindLabel,
            metadata: [framerMessage]
        )
        connection.send(
            content: payload,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { error in
                guard let error else {
                    return
                }
                logger.error(
                    """
                    control send failed kind=\(message.kindLabel, privacy: .public) \
                    error=\(error.localizedDescription, privacy: .public)
                    """
                )
            }
        )
    }

    private func sendStatusSnapshot(on connection: NWConnection) {
        let status: RelayControlMessage.Status
        if let provider = statusProvider {
            status = provider()
        } else {
            status = RelayControlMessage.Status(hasCellularPath: false)
        }
        logger.debug(
            "control status push hasCellularPath=\(status.hasCellularPath, privacy: .public)"
        )
        send(.status(status), on: connection)
    }

    // A repeating dispatch timer fires the periodic status push instead of a
    // sleep loop, satisfying the sleep_in_production rule. The handler is
    // `@Sendable` so it stays nonisolated and runs on the client queue; without
    // it the closure inherits MainActor isolation and dispatch firing it off the
    // main thread traps. It hops to the MainActor through a Task for the
    // connection and status-provider access.
    private func startStatusLoop() {
        statusTimer?.cancel()
        logger.notice(
            "control status loop starting intervalSeconds=\(statusPushIntervalSeconds, privacy: .public)"
        )
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .seconds(Int(statusPushIntervalSeconds)),
            repeating: .seconds(Int(statusPushIntervalSeconds))
        )
        timer.setEventHandler { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let connection else {
                    return
                }
                sendStatusSnapshot(on: connection)
            }
        }
        timer.resume()
        statusTimer = timer
    }
}

//
//  PhoneControlListener.swift
//  CellTunnelPhoneTunnel
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-25.
//  Copyright © 2026
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .relay)
private let statusPushIntervalSeconds: UInt64 = 5
private let controlListenerRestartDelaySeconds: Double = 2

// MARK: - Control listener

@MainActor
final class PhoneControlListener {
    typealias EndpointHandler = @MainActor (RelayEndpoint) -> Void
    typealias StatusProvider = @MainActor () -> RelayControlMessage.Status

    private let queue = DispatchQueue(label: "io.goodkind.celltunnel.controlListener")
    private var listener: NWListener?
    private var currentConnection: NWConnection?
    private var statusTimer: DispatchSourceTimer?

    var onSetServerEndpoint: EndpointHandler?
    var statusProvider: StatusProvider?
    private(set) var listenerPort: UInt16?
    private(set) var advertisedServiceName: String?
    private(set) var lastError: String?

    // Retained so the listener can be re-created with the same name after a
    // transient Bonjour failure (NWError -65563 ServiceNotRunning, which every
    // advertiser on the device hits when mDNSResponder restarts). Cleared by
    // stop() so a deliberate stop does not trigger a restart.
    private var restartServiceName: String?
    private var restartRequiredInterface: NWInterface?
    private var isControlRestartPending = false

    func start(preferredServiceName: String, requiredInterface: NWInterface?) {
        stop()
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        // The Mac reaches this control listener over the USB link. Pinning the
        // listener to that wired interface keeps its inbox on the USB link
        // rather than the cellular interface.
        if let requiredInterface {
            parameters.requiredInterface = requiredInterface
        }
        let framerOptions = RelayControlFramerSupport.framerOptions()
        parameters.defaultProtocolStack.applicationProtocols.insert(framerOptions, at: 0)

        let nwListener: NWListener
        do {
            if let bindPort = NWEndpoint.Port(rawValue: relayControlListenerDefaultPort) {
                nwListener = try NWListener(using: parameters, on: bindPort)
            } else {
                nwListener = try NWListener(using: parameters)
            }
        } catch {
            lastError = error.localizedDescription
            logger.error(
                "control listener create failed error=\(error.localizedDescription, privacy: .public)"
            )
            return
        }

        nwListener.service = NWListener.Service(
            name: preferredServiceName,
            type: relayControlServiceType
        )
        advertisedServiceName = preferredServiceName
        restartServiceName = preferredServiceName
        restartRequiredInterface = requiredInterface
        isControlRestartPending = false

        nwListener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.accept(connection)
            }
        }
        nwListener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handle(listenerState: state)
            }
        }
        nwListener.start(queue: queue)
        listener = nwListener
        logger.notice(
            """
            control listener starting service=\(relayControlServiceType, privacy: .public) \
            name=\(preferredServiceName, privacy: .public) \
            port=\(relayControlListenerDefaultPort, privacy: .public)
            """
        )
        startStatusLoop()
    }

    func stop() {
        statusTimer?.cancel()
        statusTimer = nil
        currentConnection?.cancel()
        currentConnection = nil
        listener?.cancel()
        listener = nil
        listenerPort = nil
        advertisedServiceName = nil
        restartServiceName = nil
        restartRequiredInterface = nil
        isControlRestartPending = false
        logger.notice("control listener stopped")
    }

    private func handle(listenerState state: NWListener.State) {
        switch state {
        case .ready:
            listenerPort = listener?.port?.rawValue
            // A successful (re)advertisement clears any prior transient error so a
            // recovered listener does not keep reporting a stale failure.
            lastError = nil
            logger.notice(
                "control listener ready port=\(self.listenerPort ?? 0, privacy: .public)"
            )
        case .failed(let error):
            lastError = error.localizedDescription
            logger.error(
                "control listener failed error=\(error.localizedDescription, privacy: .public)"
            )
            scheduleControlRestartAfterFailure()
        case .cancelled:
            listenerPort = nil
            logger.notice("control listener cancelled")
        default:
            logger.debug("control listener state changed")
        }
    }

    private func accept(_ connection: NWConnection) {
        logger.notice(
            """
            control listener accepting connection \
            endpoint=\(String(describing: connection.endpoint), privacy: .public)
            """
        )
        if let existing = currentConnection {
            logger.notice("control listener replacing previous control connection")
            existing.cancel()
        }
        currentConnection = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor [weak self, weak connection] in
                guard let connection else {
                    return
                }
                self?.handle(connectionState: state, connection: connection)
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func handle(connectionState state: NWConnection.State, connection: NWConnection) {
        switch state {
        case .failed(let error):
            logger.error(
                "control connection failed error=\(error.localizedDescription, privacy: .public)"
            )
            if currentConnection === connection {
                currentConnection = nil
            }
            connection.cancel()
        case .cancelled:
            if currentConnection === connection {
                currentConnection = nil
                logger.notice("control connection cancelled")
            }
        default:
            break
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, isComplete, error in
            if let error {
                logger.error(
                    "control connection receive failed error=\(error.localizedDescription, privacy: .public)"
                )
                Task { @MainActor [weak self, weak connection] in
                    guard let connection else { return }
                    if self?.currentConnection === connection {
                        self?.currentConnection = nil
                    }
                    connection.cancel()
                }
                return
            }

            if let data, !data.isEmpty {
                Task { @MainActor [weak self, weak connection] in
                    guard let connection else { return }
                    self?.handlePayload(data, connection: connection)
                }
            }

            guard !isComplete, let connection else {
                return
            }

            Task { @MainActor [weak self, weak connection] in
                guard let connection else { return }
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
                "control received error from peer code=\(payload.code, privacy: .public) message=\(payload.message, privacy: .public)"
            )
        }
    }

    private func send(_ message: RelayControlMessage, on connection: NWConnection) {
        let payload: Data
        do {
            payload = try RelayControlMessageCodec.encode(message)
        } catch {
            logger.error(
                "control encode failed kind=\(message.kindLabel, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
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
                guard let error else { return }
                logger.error(
                    "control send failed kind=\(message.kindLabel, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
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
    // sleep loop, satisfying the sleep_in_production rule. The timer fires on the
    // listener queue, then hops to the MainActor to read state and send, since the
    // connection and status provider are MainActor-isolated.
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
        // The handler must be @Sendable so it stays nonisolated and runs on the
        // listener queue without a MainActor executor assertion; it then hops to
        // the MainActor for the actual connection and status-provider access.
        timer.setEventHandler { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let connection = currentConnection else {
                    return
                }
                sendStatusSnapshot(on: connection)
            }
        }
        timer.resume()
        statusTimer = timer
    }
}

// MARK: - Transient-failure recovery

extension PhoneControlListener {
    // A control listener that fails with a transient Bonjour error stays down
    // unless re-created, which would leave the Mac unable to reach the relay
    // control channel. This re-runs start with the same name after a short delay,
    // guarding against pile-up and against a deliberate stop that cleared the
    // retained name. The restart hops back to the MainActor through a Task so the
    // delayed dispatch closure stays nonisolated and never asserts isolation.
    func scheduleControlRestartAfterFailure() {
        guard let serviceName = restartServiceName, !isControlRestartPending else {
            return
        }
        isControlRestartPending = true
        logger.notice(
            "control listener scheduling restart after transient failure delaySeconds=\(Int(controlListenerRestartDelaySeconds), privacy: .public)"
        )
        queue.asyncAfter(deadline: .now() + controlListenerRestartDelaySeconds) { [weak self] in
            Task { @MainActor [weak self] in
                self?.performControlRestart(expectedServiceName: serviceName)
            }
        }
    }

    private func performControlRestart(expectedServiceName: String) {
        isControlRestartPending = false
        guard restartServiceName == expectedServiceName else {
            logger.notice("control listener restart skipped because it was stopped")
            return
        }
        start(
            preferredServiceName: expectedServiceName,
            requiredInterface: restartRequiredInterface
        )
    }
}

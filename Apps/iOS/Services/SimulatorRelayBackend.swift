//
//  SimulatorRelayBackend.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-02.
//  Copyright © 2026, all rights reserved.
//

#if targetEnvironment(simulator)
    import CellTunnelCore
    import CellTunnelLog
    import Foundation
    import Network

    private let logger = CellTunnelLog.logger(category: .relay)

    // MARK: - Constants

    private let passthroughStateText = "Passthrough"
    private let connectingStateText = "Connecting"
    private let acknowledgeRequestKind = "set-server-endpoint"

    // MARK: - SimulatorRelayBackend

    /// Drives the relay UI in the iOS Simulator, where a Network Extension packet
    /// tunnel cannot run. It does not fabricate a routing session. Instead it
    /// exercises the real control path through the shared `CellTunnelCore`
    /// primitives: it browses for the Mac agent's control service, dials it with the
    /// shared `RelayControlFramer`, decodes the agent's `setServerEndpoint` with the
    /// shared `RelayControlMessageCodec`, and acknowledges it. A reached agent maps
    /// to passthrough, since the simulator can establish the link but cannot capture
    /// or route device packets. Counters stay zero because there is no data plane.
    @MainActor
    final class SimulatorRelayBackend: RelayControlBackend {
        private let queue = DispatchQueue(label: "io.goodkind.celltunnel.simulatorBackend")
        private var browser: NWBrowser?
        private var connection: NWConnection?

        private var attempting = false
        private var peerName: String?
        private var linkInterfaceName: String?
        private var serverEndpoint: RelayEndpoint?
        private var lastError: String?

        // MARK: - Lifecycle

        func start() async {
            logger.notice("simulator relay backend start: browsing for the agent control service")
            await Task.yield()
            attempting = true
            let parameters = NWParameters()
            parameters.includePeerToPeer = true
            let descriptor = NWBrowser.Descriptor.bonjour(
                type: relayControlServiceType, domain: nil)
            let nwBrowser = NWBrowser(for: descriptor, using: parameters)
            nwBrowser.browseResultsChangedHandler = { [weak self] results, _ in
                guard let result = results.first(where: { isService($0.endpoint) }) else {
                    return
                }
                Task { @MainActor [weak self] in
                    self?.connectIfNeeded(to: result.endpoint)
                }
            }
            nwBrowser.start(queue: queue)
            browser = nwBrowser
        }

        func stop() async {
            logger.notice("simulator relay backend stop")
            await Task.yield()
            attempting = false
            connection?.cancel()
            connection = nil
            browser?.cancel()
            browser = nil
            peerName = nil
            serverEndpoint = nil
            linkInterfaceName = nil
        }

        // MARK: - Sampling

        func sample() async -> RelayStatusSample? {
            await Task.yield()
            guard attempting else {
                return nil
            }
            let connected = serverEndpoint != nil
            return RelayStatusSample(
                isRunning: true,
                relayStateDescription: connected ? passthroughStateText : connectingStateText,
                connectedPeerName: peerName,
                cellularPath: CellularPathSnapshot(
                    isSatisfied: connected,
                    interfaceName: linkInterfaceName
                ),
                counters: TunnelCounters(),
                lastError: lastError,
                routeState: .notInstalled,
                peerState: connected ? .wireGuardConfigured : .relaySelected,
                localLinkInterfaceName: linkInterfaceName,
                relayPublicIPv4Address: relayAddress(family: .ipv4),
                relayPublicIPv6Address: relayAddress(family: .ipv6)
            )
        }

        // MARK: - Dial

        private func connectIfNeeded(to endpoint: NWEndpoint) {
            guard connection == nil else {
                return
            }
            peerName = serviceName(of: endpoint)
            logger.notice("simulator relay backend dialing the agent control service")
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            parameters.defaultProtocolStack.applicationProtocols.insert(
                NWProtocolFramer.Options(definition: RelayControlFramer.definition), at: 0)
            let nwConnection = NWConnection(to: endpoint, using: parameters)
            connection = nwConnection
            nwConnection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handle(connectionState: state)
                }
            }
            nwConnection.start(queue: queue)
        }

        private func handle(connectionState state: NWConnection.State) {
            switch state {
            case .ready:
                linkInterfaceName = connection?.currentPath?.availableInterfaces.first?.name
                receiveServerEndpoint()
            case .failed(let error):
                lastError = error.localizedDescription
                logger.error(
                    "simulator relay backend connection failed error=\(error.localizedDescription, privacy: .public)"
                )
            case .waiting(let error):
                lastError = error.localizedDescription
            default:
                break
            }
        }

        // MARK: - Handshake

        // The agent sends `setServerEndpoint` on accept and waits for an
        // acknowledge. Receiving and acknowledging it through the shared codec
        // proves the control link end to end.
        private func receiveServerEndpoint() {
            guard let connection else {
                return
            }
            connection.receiveMessage { [weak self] data, _, _, error in
                Task { @MainActor [weak self] in
                    self?.handleReceived(data: data, error: error)
                }
            }
        }

        private func handleReceived(data: Data?, error: NWError?) {
            if let error {
                lastError = error.localizedDescription
                return
            }
            guard let data, !data.isEmpty else {
                return
            }
            do {
                let message = try RelayControlMessageCodec.decode(data)
                guard case .setServerEndpoint(let payload) = message else {
                    receiveServerEndpoint()
                    return
                }
                serverEndpoint = payload.endpoint
                logger.notice("simulator relay backend received server endpoint, link is up")
                sendAcknowledge()
            } catch {
                lastError = String(describing: error)
                logger.error(
                    "simulator relay backend decode failed error=\(String(describing: error), privacy: .public)"
                )
            }
        }

        private func sendAcknowledge() {
            guard let connection else {
                return
            }
            let message = RelayControlMessage.acknowledge(
                RelayControlMessage.Acknowledge(requestKind: acknowledgeRequestKind))
            let payload: Data
            do {
                payload = try RelayControlMessageCodec.encode(message)
            } catch {
                lastError = String(describing: error)
                logger.error(
                    "simulator relay backend acknowledge encode failed error=\(String(describing: error), privacy: .public) recovery=skip-acknowledge"
                )
                return
            }
            let context = NWConnection.ContentContext(
                identifier: message.kindLabel,
                metadata: [NWProtocolFramer.Message(definition: RelayControlFramer.definition)]
            )
            connection.send(
                content: payload,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        logger.error(
                            "simulator relay backend acknowledge send failed error=\(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
            )
        }

        // MARK: - Mapping

        // Reports the relay server address the agent named, matched to the
        // requested family, since it is the public identity device traffic would
        // egress through. The agent declares the family on the endpoint.
        private func relayAddress(family: RelayAddressFamily) -> String? {
            guard let endpoint = serverEndpoint, !endpoint.host.isEmpty else {
                return nil
            }
            guard endpoint.addressFamily == family else {
                return nil
            }
            return endpoint.host
        }
    }

    // MARK: - Endpoint helpers

    private func isService(_ endpoint: NWEndpoint) -> Bool {
        if case .service = endpoint {
            return true
        }
        return false
    }

    private func serviceName(of endpoint: NWEndpoint) -> String? {
        guard case .service(let name, _, _, _) = endpoint else {
            return nil
        }
        return name
    }
#endif

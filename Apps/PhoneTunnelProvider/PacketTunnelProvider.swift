//
//  PacketTunnelProvider.swift
//  CellTunnelPhoneTunnel
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-29.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network
import NetworkExtension
import Synchronization

private let logger = CellTunnelLog.logger(category: .daemon)

// The provider installs a no-route tunnel so neither the phone's own traffic nor
// the relay's cellular socket is captured, then runs the iPhone relay data plane
// in the background. The server endpoint is not in providerConfiguration; it
// arrives at runtime over the Mac control channel via the control listener.
private let tunnelRemoteAddress = "127.0.0.1"
private let tunnelLocalAddress = "10.7.0.2"
private let tunnelLocalSubnetMask = "255.255.255.255"

// A unique-local IPv6 address for the tunnel interface so iOS reports a VPN IPv6
// address. It is a host address with no included routes, matching the IPv4
// address, so the provider still captures none of the phone's traffic.
private let tunnelLocalAddressIPv6 = "fd00::2"
private let tunnelLocalIPv6PrefixLength: NSNumber = 128

// The completion handler arrives from Objective-C without a Sendable marking;
// box it so the start Task can call it across the concurrency boundary.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

// Latest relay observations the forwarder pushes through its callbacks, held off
// the MainActor so `handleAppMessage` can read them for the status snapshot
// without a hop. The forwarder owns the per-packet path; this is only state.
// MARK: - RelayStatusState

private struct RelayStatusState {
    var running = false
    var lastError: String?
    var connectedPeerName: String?
    var relayState = WireGuardDatagramRelayState.stopped.displayName
    // The user's routing choice, defaulting to passthrough. The provider reports
    // it as the route state and pushes it to the agent, which owns the routes.
    var routingEnabled = false
}

// NEPacketTunnelProvider serializes the tunnel lifecycle callbacks, so the state
// mutated across start and stop is never touched concurrently. The relay
// observations and the cellular snapshot are additionally `Mutex`-guarded so the
// status path can read them from any thread.
// MARK: - PacketTunnelProvider

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let forwarder = PhoneRelayForwarder()
    private let controlClient = PhoneControlClient()
    private let cellularObserver = CellularPathObserver()
    private let probe = RelayPathProbe()
    private let statusState = Mutex(RelayStatusState())

    // Held so the stop can complete after teardown finishes; invoked once.
    private var stopCompletion: (() -> Void)?

    override init() {
        super.init()
        logger.notice("PhoneTunnelProvider initialized")
    }

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let optionCount = options?.count ?? 0
        logger.notice(
            "tunnel start request received optionsCount=\(optionCount, privacy: .public)"
        )

        let ipv4Settings = NEIPv4Settings(
            addresses: [tunnelLocalAddress],
            subnetMasks: [tunnelLocalSubnetMask]
        )
        let ipv6Settings = NEIPv6Settings(
            addresses: [tunnelLocalAddressIPv6],
            networkPrefixLengths: [tunnelLocalIPv6PrefixLength]
        )
        // No includedRoutes on either family: the provider must capture neither
        // the phone's traffic nor the relay's own cellular socket, so the relay
        // can egress.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelRemoteAddress)
        settings.ipv4Settings = ipv4Settings
        settings.ipv6Settings = ipv6Settings

        logger.notice(
            """
            tunnel network settings prepared remote=\(tunnelRemoteAddress, privacy: .public) \
            local=\(tunnelLocalAddress, privacy: .public)
            """
        )
        let handlerBox = UncheckedSendableBox(completionHandler)
        self.setTunnelNetworkSettings(settings) { [weak self] error in
            if let error {
                logger.error(
                    """
                    setTunnelNetworkSettings failed \
                    details=\(String(describing: error), privacy: .public) \
                    recovery=propagate-to-NE
                    """
                )
                handlerBox.value(error)
                return
            }
            logger.notice("setTunnelNetworkSettings applied success=true")
            self?.startRelayRuntime()
            handlerBox.value(nil)
        }
    }

    // Brings up the relay data plane the provider owns: the cellular path
    // observer, the forwarder callbacks wired into status state, the forwarder
    // that browses for the agent relay service and dials it, and the control
    // client that dials the agent for the WireGuard server endpoint.
    private func startRelayRuntime() {
        cellularObserver.start()
        configureForwarderCallbacks()
        forwarder.start()
        configureTransportSelection()
        startControlClient()
        statusState.withLock { $0.running = true }
        logger.notice("relay runtime started")
    }

    // Wires the discovery probe to the forwarder, then starts it. The probe
    // reports the set of interfaces the agent is reachable on whenever it
    // changes; the forwarder keeps one warm link per interface and selects the
    // egress with the shared policy. Starting the probe last means the first
    // discovery arrives with the forwarder already running.
    private func configureTransportSelection() {
        let relayForwarder = self.forwarder
        probe.onDiscover = { interfaces in
            relayForwarder.reconcileLinks(interfaces)
        }
        probe.start()
        logger.notice("relay transport selection configured")
    }

    private func configureForwarderCallbacks() {
        logger.notice("phone relay forwarder callbacks configured")
        forwarder.onStateChange = { [weak self] state in
            self?.statusState.withLock { $0.relayState = state.displayName }
            logger.notice(
                "phone relay state changed state=\(state.rawValue, privacy: .public)"
            )
        }
        forwarder.onError = { [weak self] message in
            self?.statusState.withLock { $0.lastError = message }
            logger.error("phone relay reported error=\(message, privacy: .public)")
        }
        forwarder.onPeerChange = { [weak self] name in
            self?.statusState.withLock { $0.connectedPeerName = name }
            logger.notice(
                "phone relay peer changed peer=\(name ?? "none", privacy: .public)"
            )
        }
    }

    private func startControlClient() {
        logger.notice("phone control client starting")
        let client = self.controlClient
        let relayForwarder = self.forwarder
        let observer = self.cellularObserver
        // statusState is a non-copyable Mutex, so it cannot be hoisted into a
        // local; the status closure borrows it through a weak self instead.
        Task { @MainActor [weak self] in
            client.onSetServerEndpoint = { endpoint in
                relayForwarder.setServerEndpoint(endpoint)
            }
            client.onConnectionDropped = {
                relayForwarder.resetLinks()
            }
            client.statusProvider = {
                let lastError = self.flatMap { provider in
                    provider.statusState.withLock { $0.lastError }
                }
                let cellularPath = observer.snapshot
                return RelayControlMessage.Status(
                    hasCellularPath: cellularPath.isSatisfied,
                    cellularInterface: cellularPath.interfaceName,
                    lastError: lastError,
                    counters: relayForwarder.metrics.snapshot()
                )
            }
            client.start()
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        logger.notice(
            "tunnel stop request received reason=\(String(describing: reason), privacy: .public)"
        )
        stopCompletion = completionHandler
        teardownRelayRuntime()
        finishStop()
    }

    private func teardownRelayRuntime() {
        let client = self.controlClient
        Task { @MainActor in
            client.stop()
        }
        probe.stop()
        forwarder.stop()
        cellularObserver.stop()
        statusState.withLock { state in
            state.running = false
            state.connectedPeerName = nil
            state.relayState = WireGuardDatagramRelayState.stopped.displayName
        }
        logger.notice("relay runtime torn down on shutdown")
    }

    private func finishStop() {
        stopCompletion?()
        stopCompletion = nil
        logger.notice("tunnel stop completion handler called")
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)?
    ) {
        let handlerBox = UncheckedSendableBox(completionHandler)
        let request: ProviderControlRequest
        do {
            request = try JSONDecoder().decode(
                ProviderControlEnvelope.self,
                from: messageData
            ).request
        } catch {
            logger.error(
                """
                app message decode failed \
                details=\(String(describing: error), privacy: .public) \
                recovery=reply-failure
                """
            )
            handlerBox.value?(encodeResponse(failureMessage: "decode failed"))
            return
        }
        let response = handleProviderRequest(request)
        handlerBox.value?(encodeResponse(response))
    }

    private func handleProviderRequest(
        _ request: ProviderControlRequest
    ) -> ProviderControlResponse {
        switch request {
        case .status:
            return ProviderControlResponse(status: currentStatusSnapshot())
        case .reloadConfig:
            // WireGuard runs on the Mac; the iPhone relay holds no config to reload.
            return ProviderControlResponse(status: currentStatusSnapshot())
        case .setRouteState:
            // Route gating is a Mac-side concern; the iPhone relay ignores it.
            return ProviderControlResponse(status: currentStatusSnapshot())
        case .setRoutingEnabled(let enabled):
            statusState.withLock { $0.routingEnabled = enabled }
            let client = controlClient
            Task { @MainActor in client.sendRoutingEnabled(enabled) }
            return ProviderControlResponse(status: currentStatusSnapshot())
        case .discoverySnapshot:
            return ProviderControlResponse(discovery: TunnelDiscoverySnapshot())
        }
    }

    private func currentStatusSnapshot() -> TunnelDaemonStatusSnapshot {
        let state = statusState.withLock { $0 }
        return TunnelDaemonStatusSnapshot(
            running: state.running,
            routeState: state.routingEnabled ? .installed : .notInstalled,
            peerState: state.running ? .relaySelected : .notSelected,
            lastError: state.lastError,
            phoneCounters: forwarder.metrics.snapshot(),
            cellularPath: cellularObserver.snapshot,
            connectedPeerName: state.connectedPeerName,
            relayState: state.relayState
        )
    }

    private func encodeResponse(_ response: ProviderControlResponse) -> Data? {
        do {
            return try JSONEncoder().encode(response)
        } catch {
            logger.error(
                """
                app message response encode failed \
                details=\(String(describing: error), privacy: .public) \
                recovery=reply-failure
                """
            )
            return encodeResponse(failureMessage: "encode failed")
        }
    }

    private func encodeResponse(failureMessage: String) -> Data? {
        do {
            return try JSONEncoder().encode(
                ProviderControlResponse(failureMessage: failureMessage)
            )
        } catch {
            logger.error(
                """
                app message failure encode failed \
                details=\(String(describing: error), privacy: .public) \
                recovery=reply-nil
                """
            )
            return nil
        }
    }
}

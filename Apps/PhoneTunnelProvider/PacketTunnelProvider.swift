//
//  PacketTunnelProvider.swift
//  CellTunnelPhoneTunnel
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-29.
//  Copyright © 2026
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network
import NetworkExtension
import Synchronization

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .daemon)

// The provider installs a no-route tunnel so neither the phone's own traffic nor
// the relay's cellular socket is captured, then runs the iPhone relay data plane
// in the background. The server endpoint is not in providerConfiguration; it
// arrives at runtime over the Mac control channel via the control listener.
private let tunnelRemoteAddress = "127.0.0.1"
private let tunnelLocalAddress = "10.7.0.2"
private let tunnelLocalSubnetMask = "255.255.255.255"
// Bounded wait for the path monitor to surface the USB wired interface before
// the relay listeners start. The phone is plugged in at start, so a satisfied
// path arrives within milliseconds; this only guards the no-path case.
private let localLinkResolveTimeoutSeconds: Double = 3

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
private struct RelayStatusState {
    var running = false
    var lastError: String?
    var connectedPeerName: String?
    var relayState = WireGuardDatagramRelayState.stopped.displayName
}

// NEPacketTunnelProvider serializes the tunnel lifecycle callbacks, so the state
// mutated across start and stop is never touched concurrently. The relay
// observations and the cellular snapshot are additionally `Mutex`-guarded so the
// status path can read them from any thread.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let forwarder = PhoneRelayForwarder()
    private let controlListener = PhoneControlListener()
    private let cellularObserver = CellularPathObserver()
    private let interfaceResolver = LocalLinkInterfaceResolver()
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
        // No includedRoutes: the provider must capture neither the phone's
        // traffic nor the relay's own cellular socket, so the relay can egress.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelRemoteAddress)
        settings.ipv4Settings = ipv4Settings

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
    // observer, the forwarder callbacks wired into status state, the control
    // listener that receives the server endpoint over the Mac channel, and the
    // forwarder's local listener advertising the relay Bonjour service.
    private func startRelayRuntime() {
        logger.notice("relay runtime starting; resolving USB interface")
        cellularObserver.start()
        configureForwarderCallbacks()
        statusState.withLock { $0.running = true }
        // Resolve the USB wired interface first so both listeners can pin to it
        // with requiredInterface, then start them once the interface is known.
        interfaceResolver.resolve(
            timeoutSeconds: localLinkResolveTimeoutSeconds
        ) { [weak self] usbInterface in
            self?.startListeners(requiredInterface: usbInterface)
        }
    }

    private func startListeners(requiredInterface: NWInterface?) {
        startControlListener(requiredInterface: requiredInterface)

        let listenerPort = resolvedRelayListenerPort(
            defaults: UserDefaults(suiteName: cellTunnelAppGroupIdentifier) ?? .standard
        )
        let serviceName = resolvedRelayServiceName()
        forwarder.startListener(
            port: listenerPort,
            serviceName: serviceName,
            requiredInterface: requiredInterface
        )
        logger.notice(
            """
            relay runtime started serviceName=\(serviceName, privacy: .public) \
            port=\(listenerPort.rawValue, privacy: .public) \
            requiredInterface=\(requiredInterface?.name ?? "none", privacy: .public)
            """
        )
    }

    private func configureForwarderCallbacks() {
        logger.notice("phone relay forwarder callbacks configured")
        forwarder.onStateChange = { [weak self] state in
            self?.statusState.withLock { snapshot in
                snapshot.relayState = state.displayName
                // Reaching ready means the relay recovered, so drop any stale
                // transient error the status snapshot still carries.
                if state == .ready {
                    snapshot.lastError = nil
                }
            }
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
        forwarder.onListenerReady = { [weak self] port in
            // A listener that re-advertises after a transient Bonjour failure
            // clears the latched error so the status reflects the recovered relay.
            if port != nil {
                self?.statusState.withLock { $0.lastError = nil }
            }
            logger.notice("phone relay listener ready port=\(port ?? 0, privacy: .public)")
        }
    }

    private func startControlListener(requiredInterface: NWInterface?) {
        let serviceName = resolvedRelayServiceName()
        logger.notice(
            "phone control listener starting serviceName=\(serviceName, privacy: .public)"
        )
        let controlListener = self.controlListener
        let forwarder = self.forwarder
        let cellularObserver = self.cellularObserver
        // statusState is a non-copyable Mutex, so it cannot be hoisted into a
        // local; the status closure borrows it through a weak self instead.
        Task { @MainActor [weak self] in
            controlListener.onSetServerEndpoint = { endpoint in
                forwarder.setServerEndpoint(endpoint)
            }
            controlListener.statusProvider = {
                let lastError = self.flatMap { provider in
                    provider.statusState.withLock { $0.lastError }
                }
                let cellularPath = cellularObserver.snapshot
                return RelayControlMessage.Status(
                    hasCellularPath: cellularPath.isSatisfied,
                    cellularInterface: cellularPath.interfaceName,
                    lastError: lastError,
                    counters: forwarder.metrics.snapshot()
                )
            }
            controlListener.start(
                preferredServiceName: serviceName,
                requiredInterface: requiredInterface
            )
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
        let controlListener = self.controlListener
        Task { @MainActor in
            controlListener.stop()
        }
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
        case .discoverySnapshot:
            return ProviderControlResponse(discovery: TunnelDiscoverySnapshot())
        }
    }

    private func currentStatusSnapshot() -> TunnelDaemonStatusSnapshot {
        let state = statusState.withLock { $0 }
        return TunnelDaemonStatusSnapshot(
            running: state.running,
            routeState: state.running ? .installed : .notInstalled,
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

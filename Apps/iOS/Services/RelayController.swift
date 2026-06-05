//
//  RelayController.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-31.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Observation

private let logger = CellTunnelLog.logger(category: .relay)
private let pollIntervalSeconds: Double = 1
private let relayStoppedStateText = "Stopped"

// MARK: - RelayStatusSample

/// One normalized reading of relay status that the shared controller publishes to
/// the views. Each platform backend fills it from its own source: the iPhone from
/// its tunnel extension, the Mac from the agent.
struct RelayStatusSample: Sendable {
    var isRunning: Bool
    var relayStateDescription: String
    var connectedPeerName: String?
    var cellularPath: CellularPathSnapshot
    var counters: TunnelCounters
    var lastError: String?
    /// Whether the program routes are installed, which the screen reads as routing
    /// (installed) versus passthrough (not installed).
    var routeState: TunnelRouteState
    /// Whether a WireGuard peer is configured, which gates the connected states.
    var peerState: TunnelPeerState
    /// The carrying link's raw interface identifier and transport class, shown on the
    /// `Connected via` row.
    var localLinkInterfaceName: String?
    var localLinkClass: RelayLinkClass?
    /// This device's and the peer's public addresses, shown under `Device / Public`
    /// and `Peer / Public`.
    var devicePublicAddresses: AddressPair
    var peerPublicAddresses: AddressPair
    /// The carrying link's local and peer addresses, shown under `Connection`.
    var localLinkAddresses: AddressPair
    var peerLinkAddresses: AddressPair
    /// The configured WireGuard endpoint hostname, shown as the relay host.
    var relayHost: String?
    /// The WireGuard server's IPv4 address, the endpoint hostname resolved to A.
    var relayServerIPv4Address: String?
    /// The WireGuard server's IPv6 address, the endpoint hostname resolved to AAAA.
    var relayServerIPv6Address: String?

    /// Maps a daemon status snapshot to one sample. Every backend builds its sample
    /// here, so the snapshot-to-sample mapping lives in one place; a backend applies
    /// only its own override afterward. Counters read from whichever side the snapshot
    /// carries, so the one mapping serves the iPhone and the Mac.
    init(snapshot: TunnelDaemonStatusSnapshot) {
        isRunning = snapshot.running
        relayStateDescription = snapshot.relayState ?? relayStoppedStateText
        connectedPeerName = snapshot.connectedPeerName
        cellularPath = snapshot.cellularPath ?? CellularPathSnapshot()
        counters = snapshot.phoneCounters ?? snapshot.macCounters ?? TunnelCounters()
        lastError = snapshot.lastError
        routeState = snapshot.routeState
        peerState = snapshot.peerState
        localLinkInterfaceName = snapshot.localLinkInterfaceName
        localLinkClass = snapshot.localLinkClass
        devicePublicAddresses = snapshot.devicePublicAddresses ?? .empty
        peerPublicAddresses = snapshot.peerPublicAddresses ?? .empty
        localLinkAddresses = snapshot.localLinkAddresses ?? .empty
        peerLinkAddresses = snapshot.peerLinkAddresses ?? .empty
        relayHost = snapshot.relayHost
        relayServerIPv4Address = snapshot.relayServerIPv4Address
        relayServerIPv6Address = snapshot.relayServerIPv6Address
    }
}

// MARK: - RelayControlBackend

/// The platform-specific source behind the shared relay UI. The iPhone backend
/// drives the on-device relay. The Mac backend reads the agent. The controller
/// owns the poll cadence and the published state, so a backend only brings its
/// session up or down and answers one status reading at a time.
@MainActor
protocol RelayControlBackend {
    /// Brings the platform relay session up. The iPhone creates and starts its
    /// tunnel. The Mac leaves the agent's tunnel untouched.
    func start() async

    /// One status reading, or `nil` when the source is briefly unavailable.
    func sample() async -> RelayStatusSample?

    /// Sets the routing choice: on installs the program routes, off returns to
    /// passthrough. The choice reaches the agent, which owns the routes, over the
    /// platform's control path.
    func setRouting(enabled: Bool) async
}

// MARK: - RelayController

/// Drives the shared relay screens. It holds the published status the views bind
/// to and runs one status poll per second against a platform backend, so the
/// views never branch on platform. The iPhone backend reads the on-device relay;
/// the Mac backend reads the agent.
@MainActor
@Observable
final class RelayController {
    private let backend: any RelayControlBackend
    private var pollTask: Task<Void, Never>?
    private var throughput: ThroughputCalculator
    private var lifetimeStore: LifetimeDataStore

    var isRunning = false
    /// Whether a start has been requested but the session is not yet running, so the
    /// screen can show `Starting relay…` distinct from a stopped session. Set when
    /// `start()` is called and cleared once a sample reports the session running.
    var isStarting = false
    var connectedPeerName: String?
    var cellularPath = CellularPathSnapshot()
    var counters = TunnelCounters()
    var lifetimeTransferredBytes: UInt64 = 0
    var lifetimeReceivedBytes: UInt64 = 0
    var lifetimeTotalBytes: UInt64 = 0
    var uploadMbps: Double = 0
    var downloadMbps: Double = 0
    var lastError: String?
    var relayStateDescription = relayStoppedStateText
    var routeState: TunnelRouteState = .notInstalled
    var peerState: TunnelPeerState = .notSelected
    var localLinkInterfaceName: String?
    var localLinkClass: RelayLinkClass?
    var localLinkAddresses = AddressPair.empty
    var peerLinkAddresses = AddressPair.empty
    var devicePublicAddresses = AddressPair.empty
    var peerPublicAddresses = AddressPair.empty
    var relayHost: String?
    var relayServerIPv4Address: String?
    var relayServerIPv6Address: String?

    init(
        backend: any RelayControlBackend,
        throughput: ThroughputCalculator,
        lifetimeStore: LifetimeDataStore
    ) {
        self.backend = backend
        self.throughput = throughput
        self.lifetimeStore = lifetimeStore
    }

    // MARK: - Lifecycle

    /// Brings the platform session up, then starts the status poll.
    func start() async {
        logger.notice("relay controller start requested")
        isStarting = true
        await backend.start()
        startPolling()
    }

    /// Suspends the status poll without touching the session, for backgrounding.
    func suspendPolling() {
        logger.notice("relay controller suspending status poll")
        stopPolling()
    }

    /// Resumes the status poll after foregrounding.
    func resumePolling() {
        logger.notice("relay controller resuming status poll")
        startPolling()
    }

    // MARK: - Poll loop

    private func startPolling() {
        pollTask?.cancel()
        throughput.reset()
        logger.notice("relay controller status poll starting")
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                if let sample = await backend.sample() {
                    apply(sample)
                }
                guard !Task.isCancelled else {
                    return
                }
                await Self.delayBetweenPolls()
            }
        }
    }

    private func stopPolling() {
        logger.notice("relay controller status poll stopping")
        pollTask?.cancel()
        pollTask = nil
    }

    private func apply(_ sample: RelayStatusSample) {
        isRunning = sample.isRunning
        if sample.isRunning {
            isStarting = false
        }
        connectedPeerName = sample.connectedPeerName
        cellularPath = sample.cellularPath
        counters = sample.counters
        let lifetime = lifetimeStore.totals(
            sessionTransferred: sample.counters.relayBytesIn,
            sessionReceived: sample.counters.relayBytesOut
        )
        lifetimeTransferredBytes = lifetime.transferred
        lifetimeReceivedBytes = lifetime.received
        lifetimeTotalBytes = lifetime.total
        lastError = sample.lastError
        relayStateDescription = sample.relayStateDescription
        routeState = sample.routeState
        peerState = sample.peerState
        localLinkInterfaceName = sample.localLinkInterfaceName
        localLinkClass = sample.localLinkClass
        localLinkAddresses = sample.localLinkAddresses
        peerLinkAddresses = sample.peerLinkAddresses
        devicePublicAddresses = sample.devicePublicAddresses
        peerPublicAddresses = sample.peerPublicAddresses
        relayHost = sample.relayHost
        relayServerIPv4Address = sample.relayServerIPv4Address
        relayServerIPv6Address = sample.relayServerIPv6Address
        let rate = throughput.update(with: sample.counters)
        uploadMbps = rate.upload
        downloadMbps = rate.download
        logger.debug("relay controller sample applied running=\(self.isRunning, privacy: .public)")
    }

    // MARK: - Routing control

    /// Requests routing (on) or passthrough (off) for the `Route traffic` switch.
    /// The backend forwards the choice to the agent, which installs or withdraws
    /// the program routes. The displayed routing-versus-passthrough state reads from
    /// the real `routeState` in the next status snapshot.
    func setRouteTraffic(enabled: Bool) async {
        logger.notice(
            "relay controller route traffic requested enabled=\(enabled, privacy: .public)")
        await backend.setRouting(enabled: enabled)
    }

    /// Spaces polls without `Task.sleep` by resuming off a dispatch queue after the
    /// configured interval.
    private static func delayBetweenPolls() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility)
                .asyncAfter(deadline: .now() + pollIntervalSeconds) {
                    continuation.resume()
                }
        }
    }

}

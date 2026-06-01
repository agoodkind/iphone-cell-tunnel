//
//  RelayController.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-31.
//  Copyright © 2026
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Observation

private let logger = CellTunnelLog.logger(category: .relay)
private let pollIntervalSeconds: Double = 1
private let relayStoppedStateText = "Stopped"
private let unknownInterfaceText = "Unknown"

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

    /// Tears the platform relay session down. The Mac leaves the agent's tunnel
    /// untouched.
    func stop() async

    /// One status reading, or `nil` when the source is briefly unavailable.
    func sample() async -> RelayStatusSample?
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
    private var throughput = ThroughputCalculator()

    var isRunning = false
    var connectedPeerName: String?
    var cellularPath = CellularPathSnapshot()
    var counters = TunnelCounters()
    var uploadMbps: Double = 0
    var downloadMbps: Double = 0
    var lastError: String?
    var relayStateDescription = relayStoppedStateText

    #if DEBUG
        var environmentChecks: [TunnelEnvironmentCheckResult] = []
    #endif

    init(backend: any RelayControlBackend) {
        self.backend = backend
    }

    // MARK: - Derived display

    /// The cellular interface name and index for the connection row, or a fallback
    /// when the path carries no interface yet.
    var cellularInterfaceDescription: String {
        guard let interfaceName = cellularPath.interfaceName else {
            return unknownInterfaceText
        }
        if let interfaceIndex = cellularPath.interfaceIndex {
            return "\(interfaceName) (\(interfaceIndex))"
        }
        return interfaceName
    }

    // MARK: - Lifecycle

    /// Brings the platform session up, then starts the status poll.
    func start() async {
        logger.notice("relay controller start requested")
        await backend.start()
        startPolling()
    }

    /// Stops the status poll, then brings the platform session down.
    func stop() async {
        logger.notice("relay controller stop requested")
        stopPolling()
        await backend.stop()
        isRunning = false
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
        connectedPeerName = sample.connectedPeerName
        cellularPath = sample.cellularPath
        counters = sample.counters
        lastError = sample.lastError
        relayStateDescription = sample.relayStateDescription
        let rate = throughput.update(with: sample.counters)
        uploadMbps = rate.upload
        downloadMbps = rate.download
        logger.debug("relay controller sample applied running=\(self.isRunning, privacy: .public)")
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

    // MARK: - Developer console actions

    #if DEBUG
        /// Restarts the relay through the platform backend.
        func restartRelay() async {
            logger.notice("relay controller relay restart requested")
            await debugBackend?.restart()
        }

        /// Refreshes the environment check rows from the platform backend.
        func refreshEnvironmentChecks() async {
            guard let debugBackend else {
                return
            }
            environmentChecks = await debugBackend.environmentChecks()
        }

        /// Runs the server probe through the platform backend.
        func probeServer(endpoint: RelayEndpoint) async -> DebugProbeResult {
            guard let debugBackend else {
                return DebugProbeResult(passed: false, detail: "Probe unavailable")
            }
            return await debugBackend.probeServer(endpoint: endpoint)
        }

        private var debugBackend: (any RelayDebugBackend)? {
            backend as? any RelayDebugBackend
        }
    #endif
}

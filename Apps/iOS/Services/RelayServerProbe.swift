//
//  RelayServerProbe.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-31.
//  Copyright © 2026, all rights reserved.
//

#if DEBUG
    import CellTunnelCore
    import CellTunnelLog
    import Foundation
    import Network

    private let logger = CellTunnelLog.logger(category: .relay)

    // MARK: - Constants

    private let pollIntervalNanoseconds: UInt64 = 100_000_000
    private let pollAttemptLimit = 30
    private let nanosecondsPerMillisecond: UInt64 = 1_000_000

    // MARK: - DebugProbeResult

    /// Result of one live debug probe, surfaced as a one-line caption in the
    /// developer console. The probe is a real network interaction against the
    /// running relay path, not a synthetic test.
    struct DebugProbeResult: Sendable {
        let passed: Bool
        let detail: String
    }

    // MARK: - RelayDebugBackend

    /// The platform debug actions the developer console drives. Both backends
    /// conform: the iPhone runs them against the on-device tunnel, the Mac runs
    /// them against the agent over XPC.
    @MainActor
    protocol RelayDebugBackend {
        /// Restarts the relay. The iPhone stops then starts its session; the Mac
        /// asks the agent to stop then start over XPC.
        func restart() async

        /// Environment facts to show as extra rows. The iPhone returns none; the
        /// Mac returns the agent's `check()` results.
        func environmentChecks() async -> [TunnelEnvironmentCheckResult]

        /// Probes the server. The iPhone pins the cellular interface; the Mac
        /// runs the same probe over the tunnel path.
        func probeServer(endpoint: RelayEndpoint) async -> DebugProbeResult
    }

    // MARK: - RelayServerProbe

    /// Namespace for the developer console's live server probe. The probe opens a
    /// UDP connection to the server and reports the reached state. The only
    /// per-platform difference is the interface pin, passed in by the caller.
    enum RelayServerProbe {
        /// Parses a `host:port` string into a `RelayEndpoint`. Splits on the last
        /// colon and validates the port range, since `RelayEndpoint` has no string
        /// parser of its own.
        static func parseEndpoint(from text: String) -> RelayEndpoint? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separatorIndex = trimmed.lastIndex(of: ":") else {
                return nil
            }
            let host = String(trimmed[trimmed.startIndex..<separatorIndex])
            let portText = String(trimmed[trimmed.index(after: separatorIndex)...])
            guard !host.isEmpty, let port = UInt16(portText), port > 0 else {
                return nil
            }
            let family: RelayAddressFamily = host.contains(":") ? .ipv6 : .ipv4
            return RelayEndpoint(addressFamily: family, host: host, port: port)
        }

        /// Opens a UDP connection to the server and reports the reached state and
        /// the local endpoint. When `pinCellular` is set and the build is not the
        /// simulator, the connection is pinned to the cellular interface, which is
        /// the iPhone relay path. Otherwise it follows the default route, which on
        /// the Mac is the tunnel path.
        static func probeServer(
            endpoint: RelayEndpoint, pinCellular: Bool
        ) async -> DebugProbeResult {
            logger.notice(
                """
                server probe starting host=\(endpoint.host, privacy: .public) \
                port=\(endpoint.port, privacy: .public) \
                pinCellular=\(pinCellular, privacy: .public)
                """
            )
            guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
                return DebugProbeResult(passed: false, detail: "Invalid port \(endpoint.port)")
            }
            let parameters = NWParameters.udp
            let transportNote = applyInterfacePin(to: parameters, pinCellular: pinCellular)
            let connection = NWConnection(
                host: NWEndpoint.Host(endpoint.host), port: port, using: parameters
            )
            let probeQueue = DispatchQueue(label: "CellTunnelPhone.DebugServerProbe")
            connection.start(queue: probeQueue)
            let outcome = await awaitConnectionReady(connection)
            let interface = connection.currentPath?.localEndpoint.map(String.init(describing:))
            connection.cancel()
            return probeResult(outcome, transportNote: transportNote, interface: interface)
        }

        // MARK: - Interface pin

        private static func applyInterfacePin(
            to parameters: NWParameters, pinCellular: Bool
        ) -> String {
            guard pinCellular else {
                return " (tunnel path)"
            }
            #if targetEnvironment(simulator)
                return " (simulator: host network)"
            #else
                parameters.requiredInterfaceType = .cellular
                return ""
            #endif
        }

        // MARK: - Outcome

        private static func probeResult(
            _ outcome: ConnectionOutcome, transportNote: String, interface: String?
        ) -> DebugProbeResult {
            let interfaceSuffix = interface.map { " via \($0)" } ?? ""
            switch outcome {
            case .failed(let message):
                return DebugProbeResult(passed: false, detail: "Failed: \(message)\(transportNote)")
            case .ready:
                return DebugProbeResult(
                    passed: true, detail: "Ready\(transportNote)\(interfaceSuffix)"
                )
            case .timedOut:
                return DebugProbeResult(passed: false, detail: "Timed out\(transportNote)")
            }
        }

        /// Bridges the connection state handler into async/await, resolving on the
        /// first ready or failed transition and falling back to a timeout driven by
        /// repeated polls. The caller owns cancellation. Waiting is built on
        /// `asyncAfter`, never `Task.sleep`, to match the relay runtime.
        private static func awaitConnectionReady(
            _ connection: NWConnection
        ) async -> ConnectionOutcome {
            logger.notice("server probe awaiting connection ready state")
            let box = ConnectionOutcomeBox()
            connection.stateUpdateHandler = { state in
                switch state {
                case .cancelled:
                    box.resolve(.failed("cancelled"))
                case .failed(let error):
                    box.resolve(.failed(error.localizedDescription))
                case .ready:
                    box.resolve(.ready)
                default:
                    break
                }
            }
            for _ in 0..<pollAttemptLimit {
                if let resolved = box.value {
                    return resolved
                }
                await asyncDelay(nanoseconds: pollIntervalNanoseconds)
            }
            return box.value ?? .timedOut
        }

        // MARK: - Waiting

        private static func asyncDelay(nanoseconds: UInt64) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let delayQueue = DispatchQueue(label: "CellTunnelPhone.DebugProbeDelay")
                let milliseconds = Int(nanoseconds / nanosecondsPerMillisecond)
                delayQueue.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - ConnectionOutcome

    private enum ConnectionOutcome: Sendable {
        case failed(String)
        case ready
        case timedOut
    }

    /// Thread-safe one-shot holder for the first connection outcome observed on the
    /// Network callback queue, read by the polling loop on the task.
    private final class ConnectionOutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: ConnectionOutcome?

        var value: ConnectionOutcome? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func resolve(_ outcome: ConnectionOutcome) {
            lock.lock()
            defer { lock.unlock() }
            if stored == nil {
                stored = outcome
            }
        }
    }
#endif

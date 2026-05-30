#if DEBUG
    import CellTunnelCore
    import CellTunnelLog
    import Foundation
    import Network

    private let logger = CellTunnelLog.logger(category: .relay)

    /// Result of a single live debug probe, surfaced as a one-line caption in the
    /// developer console. The probe is a real network interaction against the
    /// running relay infra, not a synthetic unit test.
    struct DebugProbeResult: Sendable {
        let passed: Bool
        let detail: String
    }

    /// Namespace for the developer console's live probe. The probe is a real
    /// network interaction: a UDP reachability check pinned to the cellular
    /// interface. Waiting is built on `DispatchQueue.asyncAfter` rather than
    /// `Task.sleep` to match the rest of the relay runtime.
    enum DebugConsoleProbes {
        // Named constants so the probe satisfies no_magic_numbers; every timeout
        // and interval below is referenced by name from the probe body.
        private static let pollIntervalNanoseconds: UInt64 = 100_000_000
        private static let cellularPollAttemptLimit = 30
        private static let nanosecondsPerMillisecond: UInt64 = 1_000_000

        /// Parses a "host:port" string into a `RelayEndpoint`. `RelayEndpoint`
        /// itself has no string parser, so this splits on the last colon and
        /// validates the port range before constructing the value.
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

        /// Opens a UDP `NWConnection` to the configured server, pinned to the
        /// cellular interface off-simulator, and reports the reached state and
        /// the local endpoint. This is a real iPhone -> cellular -> server test.
        static func probeServerOverCellular(endpoint: RelayEndpoint) async -> DebugProbeResult {
            logger.notice(
                """
                cellular probe starting host=\(endpoint.host, privacy: .public) \
                port=\(endpoint.port, privacy: .public)
                """
            )
            guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
                return DebugProbeResult(passed: false, detail: "Invalid port \(endpoint.port)")
            }
            let parameters = NWParameters.udp
            var transportNote = ""
            #if targetEnvironment(simulator)
                transportNote = " (simulator: host network)"
            #else
                parameters.requiredInterfaceType = .cellular
            #endif
            let connection = NWConnection(
                host: NWEndpoint.Host(endpoint.host), port: port, using: parameters
            )
            let probeQueue = DispatchQueue(label: "CellTunnelPhone.DebugCellularProbe")
            connection.start(queue: probeQueue)
            let outcome = await awaitConnectionReady(connection)
            let interface = connection.currentPath?.localEndpoint.map(String.init(describing:))
            connection.cancel()
            return cellularProbeResult(outcome, transportNote: transportNote, interface: interface)
        }

        // MARK: - Cellular probe internals

        private static func cellularProbeResult(
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

        /// Bridges an `NWConnection.stateUpdateHandler` into async/await, resolving
        /// on the first ready or failed transition and falling back to a timeout
        /// driven by repeated `asyncAfter` polls. The caller owns cancellation.
        private static func awaitConnectionReady(
            _ connection: NWConnection
        ) async -> ConnectionOutcome {
            logger.notice("cellular probe awaiting connection ready state")
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
            for _ in 0..<cellularPollAttemptLimit {
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

        private enum ConnectionOutcome: Sendable {
            case failed(String)
            case ready
            case timedOut
        }

        /// Thread-safe one-shot holder for the first connection outcome observed on
        /// the Network callback queue, read by the polling loop on the task.
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
    }
#endif

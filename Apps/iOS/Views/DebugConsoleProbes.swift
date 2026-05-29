#if DEBUG
    import CellTunnelCore
    import CellTunnelLog
    import Foundation
    import Network

    private let logger = CellTunnelLog.logger(category: .relay)

    /// Result of a single live debug probe, surfaced as a one-line caption in the
    /// developer console. The probes are real network interactions against the
    /// running relay infra, not synthetic unit tests.
    struct DebugProbeResult: Sendable {
        let passed: Bool
        let detail: String
    }

    /// Namespace for the developer console's live probes. Every probe is a real
    /// network interaction: a UDP reachability check pinned to the cellular
    /// interface, and a local loopback that drives the relay listener plus the
    /// Mac-facing receive path plus metrics without a Mac. Waiting is built on
    /// `DispatchQueue.asyncAfter` rather than `Task.sleep` to match the rest of
    /// the relay runtime.
    enum DebugConsoleProbes {
        // Named constants so the probes satisfy no_magic_numbers; every timeout,
        // interval, port, and size below is referenced by name from a probe body.
        static let loopbackPort: UInt16 = 51_999
        static let loopbackServiceName = "CellTunnelDebugLoopback"
        static let loopbackDatagramCount = 8
        static let loopbackDatagramByteCount = 64
        static let loopbackDatagramFillByte: UInt8 = 0x5A
        static let loopbackHost = "127.0.0.1"

        private static let listenerWarmupNanoseconds: UInt64 = 250_000_000
        private static let pollIntervalNanoseconds: UInt64 = 100_000_000
        private static let loopbackPollAttemptLimit = 20
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

        /// Stands up a throwaway forwarder listener on a fixed local port, sends a
        /// burst of UDP datagrams to it over loopback, and polls the Mac-facing
        /// ingress counter until it reaches the sent count. This exercises the
        /// NWListener plus the Mac-facing receive path plus metrics without a Mac.
        static func runLocalLinkLoopback() async -> DebugProbeResult {
            logger.notice("loopback probe starting port=\(loopbackPort, privacy: .public)")
            let forwarder = PhoneRelayForwarder()
            guard let port = NWEndpoint.Port(rawValue: loopbackPort) else {
                return DebugProbeResult(passed: false, detail: "Invalid loopback port")
            }
            forwarder.startListener(port: port, serviceName: loopbackServiceName)
            await asyncDelay(nanoseconds: listenerWarmupNanoseconds)
            await sendLoopbackDatagrams(to: port)
            let target = UInt64(loopbackDatagramCount)
            let observed = await pollMacIngress(forwarder: forwarder, target: target)
            forwarder.stop()
            let passed = observed >= target
            return DebugProbeResult(
                passed: passed,
                detail: "From Mac \(observed)/\(loopbackDatagramCount)"
            )
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

        // MARK: - Loopback internals

        private static func sendLoopbackDatagrams(to port: NWEndpoint.Port) async {
            logger.notice(
                "loopback probe sending datagrams count=\(loopbackDatagramCount, privacy: .public)"
            )
            let sendQueue = DispatchQueue(label: "CellTunnelPhone.DebugLoopbackSend")
            let connection = NWConnection(
                host: NWEndpoint.Host(loopbackHost), port: port, using: .udp
            )
            connection.start(queue: sendQueue)
            let payload = Data(
                repeating: loopbackDatagramFillByte, count: loopbackDatagramByteCount
            )
            for _ in 0..<loopbackDatagramCount {
                await sendOneDatagram(on: connection, payload: payload)
            }
            connection.cancel()
        }

        private static func sendOneDatagram(on connection: NWConnection, payload: Data) async {
            logger.debug("loopback probe sending one datagram")
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                connection.send(
                    content: payload,
                    completion: .contentProcessed { _ in
                        continuation.resume()
                    }
                )
            }
        }

        private static func pollMacIngress(
            forwarder: PhoneRelayForwarder, target: UInt64
        ) async -> UInt64 {
            var observed: UInt64 = 0
            for _ in 0..<loopbackPollAttemptLimit {
                observed = forwarder.metrics.snapshot().wireGuardDatagramsFromMac
                if observed >= target {
                    break
                }
                await asyncDelay(nanoseconds: pollIntervalNanoseconds)
            }
            return observed
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

//
//  AgentRelayBackend.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-31.
//  Copyright © 2026
//

#if targetEnvironment(macCatalyst)
    import CellTunnelCore
    import CellTunnelLog
    import Foundation
    @preconcurrency import XPC

    private let logger = CellTunnelLog.logger(category: .relay)

    // MARK: - Constants

    private let relayStoppedStateText = "Stopped"
    private let storedConfigPathDefaultsKey =
        "io.goodkind.celltunnel.lastWireGuardConfigPath"

    // MARK: - AgentRelayBackend

    /// Drives the Mac relay UI by reading the headless agent over XPC. The agent
    /// owns the Mac tunnel, so this backend only reads status; it does not bring a
    /// tunnel up or down. It maps the agent's status snapshot onto the shared
    /// reading the views render.
    ///
    /// Mac Catalyst cannot open an `NSXPCConnection` to a mach service, so this
    /// uses the libxpc session API, which Catalyst supports, against the agent's
    /// session mach service. The request and reply cross the wire as the
    /// `AgentControlEnvelope` and `AgentControlResponse` JSON the rest of the
    /// control plane uses, carried in one data field keyed by
    /// `agentSessionPayloadKey`, matching the agent's libxpc listener. The blocking
    /// send runs off the main actor through `AgentSessionTransport`, since the
    /// synchronous libxpc reply call must not run on the caller's target queue.
    @MainActor
    final class AgentRelayBackend: RelayControlBackend {
        private let transport = AgentSessionTransport()

        // MARK: - Lifecycle

        // The agent owns the Mac tunnel, so the Mac UI does not start or stop it.
        // start opens the session up front so the first status read is warm.
        func start() async {
            logger.notice("agent relay backend start: opening session to agent")
            await transport.open()
        }

        func stop() async {
            logger.notice("agent relay backend stop: closing session to agent")
            await transport.close()
        }

        // MARK: - Sampling

        func sample() async -> RelayStatusSample? {
            guard let response = await transport.send(.status) else {
                return nil
            }
            guard let snapshot = response.status else {
                logger.notice("agent relay status read returned no status payload")
                return nil
            }
            return makeSample(snapshot: snapshot)
        }

        private func makeSample(snapshot: TunnelDaemonStatusSnapshot) -> RelayStatusSample {
            RelayStatusSample(
                isRunning: snapshot.running,
                relayStateDescription: snapshot.relayState ?? relayStoppedStateText,
                connectedPeerName: snapshot.connectedPeerName,
                cellularPath: snapshot.cellularPath ?? CellularPathSnapshot(),
                counters: snapshot.macCounters ?? TunnelCounters(),
                lastError: snapshot.lastError
            )
        }
    }

    // MARK: - Developer console

    #if DEBUG
        extension AgentRelayBackend: RelayDebugBackend {
            // Stops the agent's tunnel, then starts it again when a WireGuard config
            // path is known from the app group. Without a known path the restart is a
            // stop, since the agent takes the config path per start over XPC.
            func restart() async {
                logger.notice("agent relay backend restart requested")
                _ = await transport.send(.stopTunnel)
                guard let configPath = storedWireGuardConfigPath() else {
                    logger.notice("agent relay restart stopped only: no stored config path")
                    return
                }
                let settings = TunnelStartSettings(
                    wireGuardConfigPath: configPath, relayEndpoint: nil
                )
                _ = await transport.send(.startTunnel(settings))
            }

            func environmentChecks() async -> [TunnelEnvironmentCheckResult] {
                logger.notice("agent relay backend environment check requested")
                guard let response = await transport.send(.check), let report = response.report
                else {
                    return []
                }
                return report.checks
            }

            func probeServer(endpoint: RelayEndpoint) async -> DebugProbeResult {
                await RelayServerProbe.probeServer(endpoint: endpoint, pinCellular: false)
            }

            private func storedWireGuardConfigPath() -> String? {
                let defaults = UserDefaults(suiteName: cellTunnelAppGroupIdentifier) ?? .standard
                let path = defaults.string(forKey: storedConfigPathDefaultsKey)
                guard let path, !path.isEmpty else {
                    return nil
                }
                return path
            }
        }
    #endif

    // MARK: - AgentSessionTransport

    /// Owns the libxpc session to the agent and runs the synchronous send off the
    /// main actor. The libxpc session is a serial actor, so one transport actor
    /// holds the session handle and serializes requests. A request that fails drops
    /// the session so the next request reconnects, which recovers from an agent
    /// restart.
    private actor AgentSessionTransport {
        private var session: XPCSession?

        // Opens the session ahead of the first request. Opening is idempotent, so a
        // warm session is reused and a closed one reconnects.
        func open() {
            _ = activeSession()
        }

        func close() {
            session?.cancel(reason: "backend stopped")
            session = nil
        }

        func send(_ request: AgentControlRequest) -> AgentControlResponse? {
            guard let session = activeSession() else {
                return nil
            }
            let payload: Data
            do {
                payload = try JSONEncoder().encode(AgentControlEnvelope(request: request))
            } catch {
                logger.error(
                    """
                    agent relay request encode failed \
                    details=\(String(describing: error), privacy: .public) recovery=nil
                    """
                )
                return nil
            }
            do {
                let reply = try session.sendSync(message: makeMessage(payload: payload))
                return decodeResponse(from: reply)
            } catch {
                logger.error(
                    """
                    agent relay request failed \
                    details=\(String(describing: error), privacy: .public) recovery=drop-session
                    """
                )
                self.session = nil
                return nil
            }
        }

        private func activeSession() -> XPCSession? {
            if let session {
                return session
            }
            do {
                let created = try XPCSession(machService: agentXPCSessionServiceName)
                session = created
                logger.notice(
                    """
                    agent relay session opened \
                    machService=\(agentXPCSessionServiceName, privacy: .public)
                    """
                )
                return created
            } catch {
                logger.error(
                    """
                    agent relay session open failed \
                    details=\(String(describing: error), privacy: .public) recovery=retry-next-read
                    """
                )
                return nil
            }
        }

        // Builds the request message by writing the JSON payload as a data value on
        // the underlying xpc dictionary, matching the agent listener's data key.
        private func makeMessage(payload: Data) -> XPCDictionary {
            let raw = xpc_dictionary_create_empty()
            payload.withUnsafeBytes { rawBuffer in
                xpc_dictionary_set_data(
                    raw, agentSessionPayloadKey, rawBuffer.baseAddress, rawBuffer.count
                )
            }
            return XPCDictionary(raw)
        }

        private func decodeResponse(from reply: XPCDictionary) -> AgentControlResponse? {
            let data = reply.withUnsafeUnderlyingDictionary { raw -> Data? in
                var length = 0
                guard
                    let pointer = xpc_dictionary_get_data(raw, agentSessionPayloadKey, &length),
                    length > 0
                else {
                    return nil
                }
                return Data(bytes: pointer, count: length)
            }
            guard let data else {
                logger.error("agent relay reply missing payload recovery=nil")
                return nil
            }
            do {
                return try JSONDecoder().decode(AgentControlResponse.self, from: data)
            } catch {
                logger.error(
                    """
                    agent relay response decode failed \
                    details=\(String(describing: error), privacy: .public) recovery=nil
                    """
                )
                return nil
            }
        }
    }
#endif

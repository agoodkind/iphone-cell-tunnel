//
//  AgentRelayBackend.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-31.
//  Copyright © 2026, all rights reserved.
//

#if targetEnvironment(macCatalyst)
    import CellTunnelCore
    import CellTunnelLog
    import Foundation

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
    /// The Mac and the command-line tool share one control client, `AgentClient`,
    /// which connects to the agent's mach service with the libxpc session API.
    @MainActor
    final class AgentRelayBackend: RelayControlBackend {
        private let client = AgentClient()

        // MARK: - Lifecycle

        // The agent owns the Mac tunnel, so the Mac UI does not start or stop it.
        // The yield keeps the no-op a real suspension point for the async contract.
        func start() async {
            logger.notice("agent relay backend start: read-only, agent owns the tunnel")
            await Task.yield()
        }

        func stop() async {
            logger.notice("agent relay backend stop: closing control client")
            await client.shutdown()
        }

        // MARK: - Sampling

        func sample() async -> RelayStatusSample? {
            do {
                let snapshot = try await client.status()
                return makeSample(snapshot: snapshot)
            } catch {
                logger.error(
                    """
                    agent relay status read failed \
                    details=\(String(describing: error), privacy: .public) recovery=keep-last-reading
                    """
                )
                return nil
            }
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
                do {
                    _ = try await client.stopTunnel()
                } catch {
                    logger.error(
                        """
                        agent relay restart stop failed \
                        details=\(String(describing: error), privacy: .public) recovery=continue
                        """
                    )
                }
                guard let configPath = storedWireGuardConfigPath() else {
                    logger.notice("agent relay restart stopped only: no stored config path")
                    return
                }
                do {
                    let settings = TunnelStartSettings(
                        wireGuardConfigPath: configPath, relayEndpoint: nil
                    )
                    _ = try await client.startTunnel(settings: settings)
                } catch {
                    logger.error(
                        """
                        agent relay restart start failed \
                        details=\(String(describing: error), privacy: .public) recovery=surface-state
                        """
                    )
                }
            }

            func environmentChecks() async -> [TunnelEnvironmentCheckResult] {
                logger.notice("agent relay backend environment check requested")
                do {
                    let report = try await client.check()
                    return report.checks
                } catch {
                    logger.error(
                        """
                        agent relay environment check failed \
                        details=\(String(describing: error), privacy: .public) recovery=empty
                        """
                    )
                    return []
                }
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
#endif

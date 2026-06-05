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

        // Sends the routing choice to the agent, which installs or withdraws the
        // program routes.
        func setRouting(enabled: Bool) async {
            do {
                _ = try await client.setRoutingEnabled(enabled)
                logger.notice(
                    "agent relay backend routing sent enabled=\(enabled, privacy: .public)")
            } catch {
                logger.error(
                    """
                    agent relay backend routing change failed \
                    details=\(String(describing: error), privacy: .public) recovery=keep-state
                    """
                )
            }
        }

        // MARK: - Sampling

        func sample() async -> RelayStatusSample? {
            do {
                let snapshot = try await client.status()
                return RelayStatusSample(snapshot: snapshot)
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
    }

#endif

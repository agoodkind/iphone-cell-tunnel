//
//  InstallationState.swift
//  CellTunnelPhone
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-06-05.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Observation

#if targetEnvironment(macCatalyst)
    import ServiceManagement
#endif

private let logger = CellTunnelLog.logger(category: .app)

// MARK: - InstallationState

/// Tracks whether the background agent is installed, so the status screen can show
/// the install-agent setup tier on a Mac that has no agent yet. The iPhone has no
/// separate agent, so it reports the agent as always present. On the Mac it reads the
/// login-item registration and whether the agent answers a status call, and it drives
/// the register and Login Items actions.
@MainActor
@Observable
final class InstallationState {
    /// Whether the agent is installed: always true on the iPhone, and on the Mac true
    /// once the login item is enabled or the agent answers a status call.
    private(set) var isAgentInstalled = true
    /// Whether the agent is registered but waiting on the user's Login Items approval,
    /// so the setup screen can route them to System Settings.
    private(set) var isApprovalPending = false

    /// Reconciles the install state from the platform. `agentReachable` is whether the
    /// last status poll reached the agent over the control transport.
    func refresh(agentReachable: Bool) {
        #if targetEnvironment(macCatalyst)
            refreshMacState(agentReachable: agentReachable)
        #else
            // The iPhone has no separate agent, so it is always present.
            _ = agentReachable
        #endif
    }

    /// Registers the agent login item, the install-agent setup action. A no-op on the
    /// iPhone, which has no separate agent.
    func registerAgent() {
        #if targetEnvironment(macCatalyst)
            registerMacAgent()
        #endif
    }

    /// Opens Login Items so the user can approve a registered-but-pending agent. A
    /// no-op on the iPhone.
    func openLoginItems() {
        #if targetEnvironment(macCatalyst)
            SMAppService.openSystemSettingsLoginItems()
        #endif
    }
}

#if targetEnvironment(macCatalyst)

    // MARK: - Mac install state

    extension InstallationState {
        /// The agent's login-item service, the source of truth for the Mac install and
        /// approval state.
        private static func agentService() -> SMAppService {
            SMAppService.agent(plistName: agentLaunchAgentPlistName)
        }

        /// Reads the agent login-item status and the reachability of the last poll. The
        /// agent counts as installed once the login item is enabled or it answers, and
        /// as approval-pending while it is registered but not yet enabled and silent.
        private func refreshMacState(agentReachable: Bool) {
            let status = Self.agentService().status
            isAgentInstalled = status == .enabled || agentReachable
            isApprovalPending = status == .requiresApproval && !agentReachable
            logger.debug(
                """
                install state refreshed status=\(status.rawValue, privacy: .public) \
                reachable=\(agentReachable, privacy: .public) \
                installed=\(self.isAgentInstalled, privacy: .public)
                """
            )
        }

        /// Registers the agent login item and, when macOS requires it, sends the user to
        /// Login Items to approve it.
        private func registerMacAgent() {
            let service = Self.agentService()
            do {
                try service.register()
                logger.notice(
                    "install state registered agent status=\(service.status.rawValue, privacy: .public)"
                )
            } catch {
                logger.error(
                    """
                    install state agent register failed \
                    details=\(String(describing: error), privacy: .public) recovery=open-login-items
                    """
                )
            }
            if service.status == .requiresApproval {
                openLoginItems()
            }
        }
    }

#endif

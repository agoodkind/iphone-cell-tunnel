//
//  InstallationState.swift
//  CellTunnelPhone
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-06-05.
//  Copyright © 2026, all rights reserved.
//

#if targetEnvironment(macCatalyst)
  import CellTunnelCore
  import CellTunnelLog
  import Foundation
  import Observation
  import ServiceManagement

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
    /// last status poll reached the agent over the control transport. The read runs off
    /// the main actor, so the caller awaits it and the main thread stays free.
    func refresh(agentReachable: Bool) async {
      await refreshMacState(agentReachable: agentReachable)
    }

    /// Registers the agent login item, the install-agent setup action. A no-op on the
    /// iPhone, which has no separate agent. The registration runs off the main actor.
    func registerAgent() async {
      await registerMacAgent()
    }

    /// Opens Login Items so the user can approve a registered-but-pending agent.
    func openLoginItems() {
      SMAppService.openSystemSettingsLoginItems()
    }
  }

  // MARK: - Mac install state

  extension InstallationState {
    /// Reads the agent login-item status and the reachability of the last poll. The
    /// agent counts as installed once the login item is enabled or it answers, and
    /// as approval-pending while it is registered but not yet enabled and silent.
    private func refreshMacState(agentReachable: Bool) async {
      let status = await Self.readAgentStatus()
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
    private func registerMacAgent() async {
      let status = await Self.registerAgentService()
      logger.notice(
        "install state registered agent status=\(status.rawValue, privacy: .public)"
      )
      if status == .requiresApproval {
        openLoginItems()
      }
    }

    // MARK: - Off-main ServiceManagement reads

    /// Reads the agent login-item status off the main thread. `SMAppService.status`
    /// performs a synchronous ServiceManagement round trip, so running it on the main
    /// actor would block the main thread; this resumes off a background queue instead.
    nonisolated private static func readAgentStatus() async -> SMAppService.Status {
      await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
          continuation.resume(
            returning: SMAppService.agent(plistName: agentLaunchAgentPlistName).status
          )
        }
      }
    }

    /// Registers the agent login item off the main thread and returns the resulting
    /// status. `SMAppService.register()` is a synchronous ServiceManagement call, so it
    /// runs off a background queue for the same reason as the status read.
    nonisolated private static func registerAgentService() async -> SMAppService.Status {
      await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          let service = SMAppService.agent(plistName: agentLaunchAgentPlistName)
          do {
            try service.register()
          } catch {
            logger.error(
              """
              install state agent register failed \
              details=\(String(describing: error), privacy: .public) recovery=open-login-items
              """
            )
          }
          continuation.resume(returning: service.status)
        }
      }
    }
  }

#endif

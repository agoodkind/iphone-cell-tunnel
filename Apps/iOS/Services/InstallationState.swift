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
  import UIKit

  private let logger = CellTunnelLog.logger(category: .app)

  /// The System Settings pane that lists Network Extension VPN configurations,
  /// which is what the tunnel saves. No pane has a documented way to open it, so this
  /// identifier can stop resolving on a future system.
  private let vpnSettingsURLString =
    "x-apple.systempreferences:com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension"

  /// The System Settings pane that lists which apps may reach devices on the local
  /// network, which is the permission a Mac needs before an iPhone can find it. As with
  /// the pane above, no identifier for it is documented, so it can stop resolving on a
  /// future system.
  private let localNetworkSettingsURLString =
    "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"

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
      #if DEBUG
        if UITestFixture.isEnabled {
          isAgentInstalled = agentReachable
          isApprovalPending = false
          return
        }
      #endif
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

    /// Opens the settings pane where local network access is granted. A Mac without it
    /// publishes nothing an iPhone can find, and the system gives an app no way to grant
    /// it, so taking a person there is the whole of what this can do.
    func openLocalNetworkSettings() {
      logger.notice("install state opening local network settings")
      open(settingsURLString: localNetworkSettingsURLString, describing: "local network")
    }

    /// Opens Network settings, where a saved VPN profile is switched on and off. The
    /// system offers no way for an app to switch a profile on for the user, so taking
    /// them there is the whole of what the app can do.
    func openVPNSettings() {
      logger.notice("install state opening vpn settings")
      open(settingsURLString: vpnSettingsURLString, describing: "vpn")
    }

    /// Opens one System Settings pane.
    ///
    /// The completion reports false only when nothing on the system handles the scheme
    /// at all. System Settings claims it, so a pane identifier that no longer resolves
    /// still reports success and simply lands a person on another pane. The steps on
    /// screen are what carry them the rest of the way, which is why they never assume
    /// which pane opened.
    private func open(settingsURLString: String, describing pane: String) {
      guard let url = URL(string: settingsURLString) else {
        logger.error(
          """
          settings url malformed pane=\(pane, privacy: .public) \
          recovery=user-opens-settings-manually
          """
        )
        return
      }
      UIApplication.shared.open(url) { opened in
        guard !opened else {
          return
        }
        logger.error(
          """
          settings open refused pane=\(pane, privacy: .public) \
          recovery=user-opens-settings-manually
          """
        )
      }
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

//
//  GuestProviderRegistration.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-01.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation

// MARK: - Constants

private let providerRegistrationLogger = CellTunnelLog.logger(category: .build)
private let providerBundleSubpath = "Contents/PlugIns/CellTunnelTunnelProvider.appex"

/// How many times to ask before giving up on the registration being readable.
///
/// Replacing the bundle leaves the first request a no-op often enough that one request
/// cannot be trusted, and the registration is not readable the instant it is accepted.
private let providerRegistrationAttempts = 5

/// How long to wait after each request before reading the registration back.
private let providerRegistrationWaitSeconds: Double = 8

// MARK: - Registration

/// Register the packet tunnel extension so the system can load it.
///
/// The system loads a packet tunnel extension from a registered copy, not from wherever
/// the agent happens to run, and macOS registers extensions on its own only for apps in
/// `/Applications`. This run installs elsewhere, so nothing registers the copy it just
/// installed and the tunnel cannot start: the agent reports that the extension returned
/// no payload, and every measurement taken afterwards describes a machine with no tunnel.
///
/// This runs on every pass rather than only the first, because a run replaces the bundle
/// the previous registration pointed at. Asking again when the registration is already
/// current costs one command and leaves it pointing at the copy this run installed.
func registerGuestTunnelProvider(shell: GuestShell, layout: GuestInstallLayout) throws {
  let bundlePath = "\(layout.agentAppPath)/\(providerBundleSubpath)"
  let identifier = tunnelProviderBundleIdentifier
  providerRegistrationLogger.debug(
    "guest tunnel provider registration starting bundle=\(bundlePath, privacy: .public)")

  for attempt in 1...providerRegistrationAttempts {
    try shell.runRemote(
      "pluginkit -a '\(bundlePath)'",
      describing: "registering the tunnel provider extension"
    )
    guestPollDelay(seconds: providerRegistrationWaitSeconds)
    let listing = try shell.captureRemote("pluginkit -m -v -i '\(identifier)'")
    if listing.output.contains(identifier) {
      providerRegistrationLogger.notice(
        "guest tunnel provider registered attempt=\(attempt, privacy: .public)")
      printToolOutput("guest: tunnel provider registered from \(bundlePath)")
      return
    }
  }

  throw ToolError.failure(
    """
    guest: the tunnel provider at \(bundlePath) is still not registered after \
    \(providerRegistrationAttempts) attempts, so the tunnel cannot start and anything \
    measured here would describe a machine with no tunnel; check that the bundle is \
    present and signed, then run this command again
    """
  )
}

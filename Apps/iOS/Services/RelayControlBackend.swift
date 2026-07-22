//
//  RelayControlBackend.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-21.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - RelayControlBackend

/// The platform-specific source behind the shared relay UI. The iPhone backend
/// drives the on-device relay. The Mac backend reads the agent. The controller
/// owns the poll cadence and the published state, so a backend only brings its
/// session up or down and answers one status reading at a time.
@MainActor
protocol RelayControlBackend {
  /// Brings the platform relay session up.
  func start() async

  /// Reads the saved tunnel state fresh from the platform without saving anything.
  func tunnelProvisioned() async -> Bool

  /// One status reading, or `nil` when the source is briefly unavailable.
  func sample() async -> RelayStatusSample?

  /// Sets the routing choice through the platform control path.
  func setRouting(enabled: Bool) async

  /// Selects the discovered peer to connect to.
  func selectPeer(id: String) async

  /// Selects which dialed-in iPhone the Mac routes egress through.
  func selectEgressPeer(id: String) async

  /// Whether this backend auto-dials the first discovered peer.
  var autoSelectsDiscoveredPeer: Bool { get }

  /// Whether available peers come from the dialed-in roster.
  var usesEgressRoster: Bool { get }

  /// Installs the tunnel profile from an imported configuration.
  func installTunnel(configURL: URL) async

  /// Loads a stored configuration's secret text on demand for the editor.
  func loadConfigText(id: UUID) async -> String?

  /// Imports a WireGuard configuration file into the config library.
  func importConfig(url: URL, name: String) async

  /// Makes a stored configuration active.
  func activateConfig(id: UUID) async

  /// Saves edited WireGuard configuration text.
  func saveConfigEdit(id: UUID, text: String) async

  /// Deletes a stored configuration.
  func deleteConfig(id: UUID) async

  /// Renames a stored configuration.
  func renameConfig(id: UUID, name: String) async

  /// Creates and stores a configuration from raw text.
  func importConfig(name: String, text: String) async
}

// MARK: - Defaults

extension RelayControlBackend {
  var autoSelectsDiscoveredPeer: Bool {
    false
  }

  var usesEgressRoster: Bool {
    false
  }

}

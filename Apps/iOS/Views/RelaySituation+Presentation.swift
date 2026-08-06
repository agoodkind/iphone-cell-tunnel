//
//  RelaySituation+Presentation.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-05.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore

// MARK: - RelayUITier

/// Which screen the status renders. A setup situation takes over the whole screen with
/// a single guided action; every other situation shows the reduced dashboard with its
/// rows, peers, and action. Only the Mac chooses its screen this way; the iPhone shows
/// its setup screen directly from whether a tunnel is saved.
enum RelayUITier: Equatable {
  case full
  case reduced
}

// MARK: - Presentation

/// The app's words and controls for each situation. The producer says which situation
/// the machine is in and this file says what that reads like, so wording changes never
/// touch a rule and `celltunnelctl` phrases the same situations its own way.
extension RelaySituation {
  /// The neutral status word shown as the switch's left label and the status line.
  var label: String {
    switch self {
    case .connecting:
      return "Connecting"
    case .failed:
      return "Error"
    case .noActiveConfig:
      return "No config selected"
    case .noAgent:
      return "Setup not finished"
    case .noConfigImported:
      return "No configuration imported"
    case .noPeerSelected:
      return "No peer selected"
    case .noPeersFound:
      #if targetEnvironment(macCatalyst)
        return "Searching for iPhones"
      #else
        return "Searching for peers"
      #endif
    case .notDiscoverable:
      return "This Mac cannot be found"
    case .notProvisioned:
      return "Tunnel not installed"
    case .readyToRoute:
      return "Ready to route traffic"
    case .routing:
      return "Routing traffic"
    case .vpnProfileDisabled:
      return "VPN turned off"
    }
  }

  /// Whether the live `Current Speed` section shows, only while traffic crosses.
  var showsSpeed: Bool {
    self == .routing
  }

  /// The offered action for the current situation, or none when the routing switch is
  /// the only control the situation needs.
  var action: RelayHeroAction? {
    switch self {
    case .failed:
      return .retry
    case .noAgent:
      return .installAgent
    case .noConfigImported:
      return .importConfig
    case .noPeerSelected:
      return .selectPeer
    case .notDiscoverable:
      return .openLocalNetworkSettings
    case .vpnProfileDisabled:
      return .enableVPN
    case .connecting, .noActiveConfig, .noPeersFound, .notProvisioned, .readyToRoute,
      .routing:
      return nil
    }
  }

  /// Which screen renders this situation: the full guided setup for the situations
  /// with one guided step, the reduced dashboard for everything else.
  var uiTier: RelayUITier {
    switch self {
    case .noAgent, .noConfigImported, .notDiscoverable, .vpnProfileDisabled:
      return .full
    case .connecting, .failed, .noActiveConfig, .noPeerSelected, .noPeersFound,
      .notProvisioned, .readyToRoute, .routing:
      return .reduced
    }
  }
}

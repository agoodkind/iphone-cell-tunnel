//
//  MacRelayStatus.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - MacRelayStatus

#if targetEnvironment(macCatalyst)

  /// Which screen the Mac status renders. A setup state takes over the whole screen
  /// with a single guided action; every other state shows the reduced dashboard with
  /// its rows, peers, and action.
  enum RelayUITier: Equatable {
    case full
    case reduced
  }

  /// What the Mac can be doing, the single value its screens render from. The cases
  /// are a set rather than a precedence chain, and each owns its screen tier, status
  /// word, whether the live speed shows, and the offered action, so the screens never
  /// infer state from a pile of separate flags. The status is peer-keyed: the relay
  /// carries nothing until the iPhone link is up, so the peer is the gate and a local
  /// interface running flag never drives it.
  ///
  /// The Mac runs a background agent and owns the configuration library, so it names
  /// those facts directly and the iPhone carries no case for either.
  enum MacRelayStatus: Equatable {
    case error(String)
    case noActiveConfig
    case noAgent
    case noConfigImported
    case noPeerSelected
    case noPeersFound
    case readyToRoute
    case routing

    /// Builds the status from named, single-purpose inputs. A failure wins, then the
    /// agent must be present, then the library must hold a configuration. An
    /// established peer link decides the rest before discovery, since a live link means
    /// the screen is connected whether or not this side browsed for it: a connected
    /// iPhone with no active configuration is the choose-a-configuration state, then
    /// routes installed is the routing state and routes withdrawn is ready to route.
    /// The split is the agent-confirmed routes, never a local running flag. Without a
    /// link, no dialed-in iPhone is the searching state and a listed but unselected
    /// iPhone is the select state.
    init(
      errorMessage: String?,
      isAgentInstalled: Bool,
      isConfigImported: Bool,
      isActiveConfigPresent: Bool,
      peersFound: Bool,
      isPeerConnected: Bool,
      isRouting: Bool
    ) {
      if let errorMessage, !errorMessage.isEmpty {
        self = .error(errorMessage)
      } else if !isAgentInstalled {
        self = .noAgent
      } else if !isConfigImported {
        self = .noConfigImported
      } else if isPeerConnected, !isActiveConfigPresent {
        self = .noActiveConfig
      } else if isPeerConnected {
        self = isRouting ? .routing : .readyToRoute
      } else if !peersFound {
        self = .noPeersFound
      } else {
        self = .noPeerSelected
      }
    }

    /// Which screen renders this state: the full guided setup for the two setup
    /// states, the reduced dashboard for everything else.
    var uiTier: RelayUITier {
      switch self {
      case .noAgent, .noConfigImported:
        return .full
      case .error, .noActiveConfig, .noPeerSelected, .noPeersFound, .readyToRoute,
        .routing:
        return .reduced
      }
    }

    /// The neutral status word shown as the switch's left label and the reduced-tier
    /// status line. The labels are neutral placeholders rather than final copy.
    var label: String {
      switch self {
      case .error:
        return "Error"
      case .noActiveConfig:
        return "No config selected"
      case .noAgent:
        return "Agent not installed"
      case .noConfigImported:
        return "No configuration imported"
      case .noPeerSelected:
        return "No peer selected"
      case .noPeersFound:
        return "Searching for peers"
      case .readyToRoute:
        return "Ready to route traffic"
      case .routing:
        return "Routing traffic"
      }
    }

    /// Whether the live `Current Speed` section shows, only while routing.
    var showsSpeed: Bool {
      self == .routing
    }

    /// The offered action for the current state, or none when the routing switch is
    /// the only control the state needs.
    var action: RelayHeroAction? {
      switch self {
      case .error:
        return .retry
      case .noAgent:
        return .installAgent
      case .noConfigImported:
        return .importConfig
      case .noPeerSelected:
        return .selectPeer
      case .noActiveConfig, .noPeersFound, .readyToRoute, .routing:
        return nil
      }
    }

    /// The error message when the status is an error, otherwise nil.
    var errorMessage: String? {
      guard case .error(let message) = self else {
        return nil
      }
      return message
    }
  }

#endif

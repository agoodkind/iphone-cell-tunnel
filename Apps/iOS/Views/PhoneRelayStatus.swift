//
//  PhoneRelayStatus.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - PhoneRelayStatus

#if !targetEnvironment(macCatalyst)

  /// What the iPhone can be doing, the single value its screen renders from. The cases
  /// are a set rather than a precedence chain, and each owns its screen tier, status
  /// word, whether the live speed shows, and the offered action, so the screen never
  /// infers state from a pile of separate flags. The status is peer-keyed: the relay
  /// carries nothing until the peer link is up, so the peer is the gate and a local
  /// interface running flag never drives it. It carries no screen tier, because the
  /// iPhone shows its setup screen directly from whether a tunnel is saved.
  ///
  /// The iPhone holds its own saved VPN profile and dials Macs it discovers, so it
  /// names those two facts directly. It never installs a background agent and never
  /// holds a configuration library, so it carries no case for either.
  enum PhoneRelayStatus: Equatable {
    case error(String)
    case noPeerSelected
    case noPeersFound
    case notProvisioned
    case readyToRoute
    case routing

    /// Builds the status from named, single-purpose inputs. A failure wins, then the
    /// saved VPN profile must exist. An established peer link decides the rest before
    /// discovery, since a live link means the screen is connected whether or not this
    /// side browsed for it: routes installed is the routing state and routes withdrawn
    /// is ready to route. The split is the agent-confirmed routes, never a local
    /// running flag. Without a link, no discovered Mac is the searching state and a
    /// discovered but unconnected Mac is the select state.
    init(
      errorMessage: String?,
      isTunnelProvisioned: Bool,
      peersFound: Bool,
      isPeerConnected: Bool,
      isRouting: Bool
    ) {
      if let errorMessage, !errorMessage.isEmpty {
        self = .error(errorMessage)
      } else if !isTunnelProvisioned {
        self = .notProvisioned
      } else if isPeerConnected {
        self = isRouting ? .routing : .readyToRoute
      } else if !peersFound {
        self = .noPeersFound
      } else {
        self = .noPeerSelected
      }
    }

    /// The neutral status word shown as the switch's left label and the status line.
    /// The labels are neutral placeholders rather than final copy.
    var label: String {
      switch self {
      case .error:
        return "Error"
      case .noPeerSelected:
        return "No peer selected"
      case .noPeersFound:
        return "Searching for peers"
      case .notProvisioned:
        return "Tunnel not installed"
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
      case .noPeerSelected:
        return .selectPeer
      case .noPeersFound, .notProvisioned, .readyToRoute, .routing:
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

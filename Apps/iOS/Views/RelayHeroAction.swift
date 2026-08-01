//
//  RelayHeroAction.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - RelayHeroAction

/// The offered call to action for the current state. Each case maps to one controller
/// operation, so the view holds no branching of its own. `selectPeer` is offered by
/// the reduced-tier peers list rather than a single button.
enum RelayHeroAction: Equatable {
  case enableVPN
  case importConfig
  case installAgent
  case retry
  case selectPeer

  /// The button title shown in the action row.
  var title: String {
    switch self {
    case .enableVPN:
      return "Open System Settings"
    case .importConfig:
      return "Import Configuration"
    case .installAgent:
      return "Set Up"
    case .retry:
      return "Retry"
    case .selectPeer:
      return "Select Peer"
    }
  }

  /// The SF Symbol shown beside the action on the setup screen.
  var systemImage: String {
    switch self {
    case .enableVPN:
      return "gearshape"
    case .importConfig:
      return "arrow.down.doc"
    case .installAgent:
      return "gearshape.2"
    case .retry:
      return "arrow.clockwise"
    case .selectPeer:
      return "person.crop.circle.badge.checkmark"
    }
  }
}

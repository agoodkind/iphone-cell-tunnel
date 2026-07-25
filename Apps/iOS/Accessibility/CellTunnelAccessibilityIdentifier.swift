//
//  CellTunnelAccessibilityIdentifier.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-22.
//  Copyright © 2026, all rights reserved.
//

import SwiftUI

// MARK: - CellTunnelAccessibilityIdentifier

enum CellTunnelAccessibilityIdentifier: String {
  case configActions = "cell-tunnel.config-actions"
  case configEditor = "cell-tunnel.config-editor"
  case deleteConfig = "cell-tunnel.delete-config"
  case editConfig = "cell-tunnel.edit-config"
  case fixtureScrollRecovery = "cell-tunnel.fixture-scroll-recovery"
  case importConfig = "cell-tunnel.import-config"
  case macStatusScroll = "cell-tunnel.mac-status-scroll"
  case newConfig = "cell-tunnel.new-config"
  case renameConfig = "cell-tunnel.rename-config"
  case routeTraffic = "cell-tunnel.route-traffic"
  case vpnApproval = "cell-tunnel.vpn-approval"
}

// MARK: - View

extension View {
  func cellTunnelAccessibilityIdentifier(
    _ identifier: CellTunnelAccessibilityIdentifier
  ) -> some View {
    accessibilityIdentifier(identifier.rawValue)
  }
}

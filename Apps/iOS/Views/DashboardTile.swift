//
//  DashboardTile.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-30.
//  Copyright © 2026, all rights reserved.
//

import SwiftUI

// MARK: - Constants

/// The corner radius shared by every dashboard tile.
private let dashboardTileCornerRadius: CGFloat = 14
/// The inner padding shared by every dashboard tile.
private let dashboardTilePadding: CGFloat = 16

// MARK: - DashboardTile

/// Wraps tile content in the shared rounded `secondarySystemBackground` shell the Configs
/// library, the Peers roster, and the Mac status tiles all use, so the three surfaces
/// cannot drift in corner radius, padding, or fill.
private struct DashboardTile: ViewModifier {
  /// Applies the full leading width, the shared padding, and the rounded fill.
  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(dashboardTilePadding)
      .background(
        RoundedRectangle(cornerRadius: dashboardTileCornerRadius, style: .continuous)
          .fill(Color(uiColor: .secondarySystemBackground))
      )
  }
}

// MARK: - View

extension View {
  /// Applies the shared dashboard tile shell: full leading width, the shared padding, and
  /// the rounded `secondarySystemBackground` fill.
  func dashboardTile() -> some View {
    modifier(DashboardTile())
  }
}

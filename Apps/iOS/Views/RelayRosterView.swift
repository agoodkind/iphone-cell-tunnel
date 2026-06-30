//
//  RelayRosterView.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-13.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import SwiftUI

// MARK: - Constants

private let rosterSectionTitle = "Peers"
private let rosterCountSuffix = "available"
private let rosterSectionSpacing: CGFloat = 12
private let rosterHeaderSpacing: CGFloat = 10
private let rosterSelectedAccessibilityLabel = "Routing peer"

// MARK: - RelayRosterView

/// Presents the dialed-in iPhones inside the shared masonry tile, the same rounded
/// `secondarySystemBackground` card the status tiles use, with the `Peers` title inside it.
/// The peers are stacked rows separated by dividers; each row is a leading checkmark on the
/// routing iPhone and the name. Tapping a row routes egress through it. The view is
/// select-only: no remove, no per-row menu. The header carries the title and a count once
/// peers exist. The subtitle, sourced from `RelayScreenModel.rosterSubtitle`, reads
/// `Searching for peers` with an empty roster and `No peer selected` when peers await a
/// choice; a selected peer passes a nil subtitle, so the checked row alone shows the choice.
struct RelayRosterView: View {
  let peers: [ConnectedPeer]
  let subtitle: String?
  let onSelect: (String) -> Void

  // MARK: - Body

  var body: some View {
    VStack(alignment: .leading, spacing: rosterSectionSpacing) {
      header
      content
    }
    .dashboardTile()
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(rosterSectionTitle)
        .font(.headline)
      Spacer(minLength: rosterHeaderSpacing)
      if !peers.isEmpty {
        Text(countLabel)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }

  /// The secondary tally of dialed-in peers, the adjective held constant so only the
  /// number changes between one and many.
  private var countLabel: String {
    "\(peers.count) \(rosterCountSuffix)"
  }

  // MARK: - Content

  @ViewBuilder private var content: some View {
    if let subtitle {
      Text(subtitle)
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    if !peers.isEmpty {
      VStack(spacing: 0) {
        ForEach(Array(peers.enumerated()), id: \.element.id) { index, peer in
          if index > 0 {
            Divider()
          }
          peerRow(peer)
        }
      }
    }
  }

  private func peerRow(_ peer: ConnectedPeer) -> some View {
    SelectableRow(
      isSelected: peer.isSelected,
      title: peer.name.isEmpty ? peer.id : peer.name,
      selectionAccessibilityLabel: rosterSelectedAccessibilityLabel,
      onTap: { onSelect(peer.id) },
      trailing: { EmptyView() }
    )
  }
}

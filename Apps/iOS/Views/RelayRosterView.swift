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
private let selectedPeerSymbol = "checkmark"
private let rosterTileCornerRadius: CGFloat = 14
private let rosterRowCornerRadius: CGFloat = 9
private let rosterTilePadding: CGFloat = 16
private let rosterHeaderSpacing: CGFloat = 12
private let rosterListSpacing: CGFloat = 4
private let rosterRowSpacing: CGFloat = 12
private let rosterRowHorizontalPadding: CGFloat = 10
private let rosterRowVerticalPadding: CGFloat = 9
private let rosterSelectedRowOpacity: Double = 0.1
private let selectedPeerAccessibilityLabel = "Selected peer"

// MARK: - RelayRosterView

/// The roster of dialed-in iPhones as a selectable tile on the Mac, the egress
/// selector, styled to match the Configs column. The header carries the `Peers`
/// title and a secondary count once peers exist; each row is just the peer name and
/// a trailing checkmark in the tint when it is selected, with a faint tint background
/// behind the selected row. Tapping a row selects it for egress. The subtitle, sourced
/// from `RelayScreenModel.rosterSubtitle`, reads `Searching for peers` with an empty
/// roster and `No peer selected` when peers await a choice; a selected peer passes a
/// nil subtitle, so the checked row alone shows the choice. Deliberately minimal: no
/// avatars, no per-peer metadata, no status sublines. SF Symbols only.
struct RelayRosterView: View {
  let peers: [ConnectedPeer]
  let subtitle: String?
  let onSelect: (String) -> Void

  // MARK: - Body

  var body: some View {
    VStack(alignment: .leading, spacing: rosterHeaderSpacing) {
      header
      peerContent
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(rosterTilePadding)
    .background(
      RoundedRectangle(cornerRadius: rosterTileCornerRadius, style: .continuous)
        .fill(Color(uiColor: .secondarySystemBackground))
    )
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(rosterSectionTitle)
        .font(.headline)
      Spacer(minLength: rosterRowSpacing)
      // The count is a quiet secondary tally shown only once peers exist, so an
      // empty roster carries the subtitle alone.
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

  // MARK: - Rows

  // The subtitle leads when it applies, centered as secondary text, then the rows
  // follow when any peer is present. An empty roster shows the subtitle alone; a
  // selected peer drops the subtitle and shows only the checked rows.
  @ViewBuilder private var peerContent: some View {
    if let subtitle {
      Text(subtitle)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
    if !peers.isEmpty {
      VStack(spacing: rosterListSpacing) {
        ForEach(peers) { peer in
          peerRow(peer)
        }
      }
    }
  }

  private func peerRow(_ peer: ConnectedPeer) -> some View {
    Button {
      onSelect(peer.id)
    } label: {
      rowLabel(peer)
    }
    .buttonStyle(.plain)
    .background(rowBackground(isSelected: peer.isSelected))
  }

  private func rowLabel(_ peer: ConnectedPeer) -> some View {
    HStack(spacing: rosterRowSpacing) {
      Text(peer.name.isEmpty ? peer.id : peer.name)
        .font(.subheadline)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
      if peer.isSelected {
        Image(systemName: selectedPeerSymbol)
          .foregroundStyle(.tint)
          .accessibilityLabel(selectedPeerAccessibilityLabel)
      }
    }
    .padding(.horizontal, rosterRowHorizontalPadding)
    .padding(.vertical, rosterRowVerticalPadding)
    .contentShape(.rect)
  }

  @ViewBuilder private func rowBackground(isSelected: Bool) -> some View {
    if isSelected {
      RoundedRectangle(cornerRadius: rosterRowCornerRadius, style: .continuous)
        .fill(.tint.opacity(rosterSelectedRowOpacity))
    }
  }
}

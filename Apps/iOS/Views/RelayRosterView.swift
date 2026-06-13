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
private let selectedPeerSymbol = "checkmark"
private let unnamedPeerText = "iPhone"
private let peerRowMinSpacing: CGFloat = 12

// MARK: - RelayRosterView

/// The roster of dialed-in iPhones as a selectable list on the Mac, the egress
/// selector. Each iPhone is a button that selects it for egress through the
/// controller; the selected one carries a checkmark. The subtitle reports the state
/// when none is selected: `No peers available` with an empty roster, or
/// `No peer selected` with one or more awaiting a choice. A selected peer passes a nil
/// subtitle, so the checked row alone shows the choice. SF Symbols only.
struct RelayRosterView: View {
  let peers: [ConnectedPeer]
  let subtitle: String?
  let onSelect: (String) -> Void

  var body: some View {
    if let subtitle {
      Text(subtitle)
        .foregroundStyle(.secondary)
    }
    ForEach(peers) { peer in
      Button {
        onSelect(peer.id)
      } label: {
        peerLabel(peer)
      }
      .buttonStyle(.plain)
    }
  }

  private func peerLabel(_ peer: ConnectedPeer) -> some View {
    HStack {
      Text(peer.name.isEmpty ? unnamedPeerText : peer.name)
      Spacer(minLength: peerRowMinSpacing)
      if peer.isSelected {
        Image(systemName: selectedPeerSymbol)
          .foregroundStyle(.tint)
      }
    }
    .contentShape(.rect)
  }
}

// MARK: - Section title

extension RelayRosterView {
  /// The group title the Mac dashboard renders above the roster.
  static var title: String {
    rosterSectionTitle
  }
}

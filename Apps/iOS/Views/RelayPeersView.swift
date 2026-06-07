//
//  RelayPeersView.swift
//  CellTunnelPhone
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-06-05.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import SwiftUI

// MARK: - Constants

private let peersSectionTitle = "Peers"
private let searchingForPeersText = "Searching for peers"
private let selectedPeerSymbol = "checkmark"
private let peerRowMinSpacing: CGFloat = 12

// MARK: - RelayPeersView

/// The discovered peers as a selectable list, shared by the iPhone list and the Mac
/// dashboard. Each peer is a button that selects it through the controller; the
/// selected peer carries a checkmark. While discovery has found nothing it shows a
/// neutral searching line, since discovery keeps running. SF Symbols only.
struct RelayPeersView: View {
  let peers: [TunnelRelayService]
  let selectedID: String?
  let onSelect: (String) -> Void

  var body: some View {
    if peers.isEmpty {
      Text(searchingForPeersText)
        .foregroundStyle(.secondary)
    } else {
      ForEach(peers) { peer in
        Button {
          onSelect(peer.id)
        } label: {
          peerLabel(peer)
        }
        .buttonStyle(.plain)
      }
    }
  }

  private func peerLabel(_ peer: TunnelRelayService) -> some View {
    HStack {
      Text(peer.serviceName)
      Spacer(minLength: peerRowMinSpacing)
      if peer.id == selectedID {
        Image(systemName: selectedPeerSymbol)
          .foregroundStyle(.tint)
      }
    }
    .contentShape(.rect)
  }
}

// MARK: - Section title

extension RelayPeersView {
  /// The group title both dashboards render above the peers list.
  static var title: String {
    peersSectionTitle
  }
}

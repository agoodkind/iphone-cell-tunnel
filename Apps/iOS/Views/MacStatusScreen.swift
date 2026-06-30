//
//  MacStatusScreen.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-05.
//  Copyright © 2026, all rights reserved.
//

#if targetEnvironment(macCatalyst)
  import CellTunnelCore
  import SwiftUI

  // MARK: - Constants

  private let screenTitle = "Cell Tunnel"
  private let routeToggleTitle = "Route traffic"
  private let dataSectionTitle = "Data"
  private let currentSpeedSectionTitle = "Current Speed"
  private let tileCornerRadius: CGFloat = 14
  // The top row and the status tiles below share this fixed two-column track so
  // their gutters line up; a flexible per-column width keeps the columns equal.
  private let columnCount = 2
  private let gridSpacing: CGFloat = 16
  private let contentPadding: CGFloat = 24
  private let headerStackSpacing: CGFloat = 4
  private let actionTopPadding: CGFloat = 4
  private let sectionWeightOverhead = 2
  private let tileContentSpacing: CGFloat = 12
  private let tileRowSpacing: CGFloat = 10
  private let tilePadding: CGFloat = 16
  // Gap between the routing switch and the in-flight spinner shown on its trailing
  // side while a routing request awaits the agent's confirmation.
  private let routeSpinnerSpacing: CGFloat = 8

  // MARK: - MacStatusScreen

  /// The Mac status screen, a single dashboard. A status header carries the title, the
  /// live status word, and the routing switch; below it a two-column top row pairs the
  /// Configs library with the Peers roster, and under that the status tiles pack into
  /// the same two columns so every gutter lines up. A value that has not arrived renders
  /// as a redacted skeleton bar. It reads the same `RelayScreenModel` the iPhone list
  /// does.
  struct MacStatusScreen: View {
    @Environment(RelayController.self) private var controller

    private var model: RelayScreenModel {
      RelayScreenModel(controller: controller)
    }

    // MARK: - Body

    var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: contentPadding) {
          header
          masonry
        }
        .padding(contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .animation(.default, value: model.status)
    }

    // MARK: - Header

    // The title and live status on the left, the single Route traffic switch on the
    // right. The switch is hidden with no peer, disabled with a choose-a-config hint
    // when a peer is connected but no config is active, and live otherwise; the error
    // message and the Retry action appear under the status when the status calls for
    // them.
    private var header: some View {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: headerStackSpacing) {
          Text(screenTitle)
            .font(.largeTitle.bold())
          // In the no-peer states the Peers tile carries the status word ("Searching for
          // peers" with no peers, "No peer selected" when none is chosen), so the Mac
          // header omits it to avoid showing the same phrase twice.
          if model.status != .noPeersFound, model.status != .noPeerSelected {
            Text(model.statusLabel)
              .font(.title3)
              .foregroundStyle(.secondary)
          }
          if let message = model.errorMessage {
            Text(message)
              .font(.callout)
              .foregroundStyle(.secondary)
          }
          if model.heroAction == .retry {
            Button(RelayHeroAction.retry.title) {
              model.startSession()
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, actionTopPadding)
          }
        }
        Spacer(minLength: gridSpacing)
        routeControlView
      }
    }

    // The Route traffic switch driven by the derived presentation: absent when
    // hidden, a disabled switch with the hint beside it when a config must be chosen,
    // and a live switch with a connect spinner when enabled.
    @ViewBuilder private var routeControlView: some View {
      switch model.routeControl.presentation {
      case .hidden:
        EmptyView()
      case .disabled(let hint):
        HStack(spacing: routeSpinnerSpacing) {
          Text(hint)
            .font(.callout)
            .foregroundStyle(.secondary)
          routeToggle
            .disabled(true)
        }
      case .enabled:
        HStack(spacing: routeSpinnerSpacing) {
          routeToggle
          if model.isConnecting {
            ProgressView()
              .controlSize(.small)
          }
        }
      }
    }

    private var routeToggle: some View {
      Toggle(routeToggleTitle, isOn: model.routeTrafficBinding)
        .toggleStyle(.switch)
        .fixedSize()
    }

    // MARK: - Masonry

    // The Configs library and the Peers roster lead the two columns, then the status tiles
    // distribute into whichever column is shorter, so every card packs tightly with no gap
    // under a short card. Configs seeds the left column and Peers the right, so their
    // positions stay stable while the status tiles balance the column heights.
    private var masonry: some View {
      let columns = distribute(
        tiles,
        into: columnCount,
        seedWeights: [configsWeight, peersWeight]
      )
      return HStack(alignment: .top, spacing: gridSpacing) {
        ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
          VStack(spacing: gridSpacing) {
            leadCard(forColumn: index)
            ForEach(column) { section in
              tile(section)
            }
          }
          .frame(maxWidth: .infinity)
        }
      }
    }

    // The lead card atop each column: the Configs library on the left, the Peers roster on
    // the right.
    @ViewBuilder private func leadCard(forColumn index: Int) -> some View {
      if index == 0 {
        ConfigLibraryView()
      } else {
        RelayRosterView(
          peers: model.connectedPeers,
          subtitle: model.rosterSubtitle
        ) { id in
          model.selectEgressPeer(id: id)
        }
      }
    }

    // The Configs and Peers cards seed their columns' heights so the status tiles balance
    // against them. Each weight is the row count plus the section overhead the status tiles
    // use, with the Configs actions row counted once.
    private var configsWeight: Int {
      controller.configLibrary.count + sectionWeightOverhead + 1
    }

    private var peersWeight: Int {
      max(model.connectedPeers.count, 1) + sectionWeightOverhead
    }

    private func distribute(
      _ sections: [ConnectionSection],
      into count: Int,
      seedWeights: [Int]
    ) -> [[ConnectionSection]] {
      var columns = Array(repeating: [ConnectionSection](), count: count)
      var weights = seedWeights
      for section in sections {
        let target = weights.indices.min { weights[$0] < weights[$1] } ?? 0
        columns[target].append(section)
        weights[target] += section.rows.count + sectionWeightOverhead
      }
      return columns
    }

    // MARK: - Tile

    // One rounded tile: the section title over its aligned rows, each rendered through
    // the shared `RelayValueRow` so a tile row reads the same as the iPhone list row.
    // The compact font sits on the rows container so every shared row inherits it.
    private func tile(_ section: ConnectionSection) -> some View {
      VStack(alignment: .leading, spacing: tileContentSpacing) {
        Text(section.title)
          .font(.headline)
        VStack(spacing: tileRowSpacing) {
          ForEach(section.rows) { row in
            RelayValueRow(row: row)
          }
        }
        .font(.subheadline)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(tilePadding)
      .background(
        RoundedRectangle(cornerRadius: tileCornerRadius, style: .continuous)
          .fill(Color(uiColor: .secondarySystemBackground))
      )
    }

    // The connection sections lead, then the lifetime data and the live speed, so the
    // status tiles come first and the totals follow.
    private var tiles: [ConnectionSection] {
      let all = model.macSections
      let summaries = Set([dataSectionTitle, currentSpeedSectionTitle])
      let connection = all.filter { !summaries.contains($0.title) }
      let totals = all.filter { summaries.contains($0.title) }
      return connection + totals
    }
  }

  // MARK: - Preview

  #Preview {
    MacStatusScreen()
      .environment(
        RelayController(
          backend: PreviewRelayBackend(),
          throughput: ThroughputCalculator(),
          lifetimeStore: LifetimeDataStore()
        )
      )
  }

#endif

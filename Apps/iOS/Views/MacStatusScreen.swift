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
    private let routeToggleTitle = "Route Traffic"
    private let dataSectionTitle = "Data"
    private let currentSpeedSectionTitle = "Current Speed"
    private let tileMinimumWidth: CGFloat = 300
    private let tileCornerRadius: CGFloat = 14
    private let maxColumns = 3
    private let gridSpacing: CGFloat = 16
    private let contentPadding: CGFloat = 24
    private let headerStackSpacing: CGFloat = 4
    private let actionTopPadding: CGFloat = 4
    private let contentInsetColumns: CGFloat = 2
    private let sectionWeightOverhead = 2
    private let tileContentSpacing: CGFloat = 12
    private let tileRowSpacing: CGFloat = 10
    private let tilePadding: CGFloat = 16
    private let valueRowSpacing: CGFloat = 12
    private let valueRowMinTrailing: CGFloat = 12
    // A value-width string drawn only as a redacted skeleton, so its characters never
    // show; it sets the placeholder bar's width.
    private let skeletonValue = "000.000.000.000"

    // MARK: - MacStatusScreen

    /// The Mac status screen, a single dashboard. A status header carries the title, the
    /// live status word, and the routing switch; below it a masonry of rounded tiles,
    /// one per section, packs by column and reflows with the window width. A value that
    /// has not arrived renders as a redacted skeleton bar. It reads the same
    /// `RelayScreenModel` the iPhone list does.
    struct MacStatusScreen: View {
        @Environment(RelayController.self) private var controller

        private var model: RelayScreenModel {
            RelayScreenModel(controller: controller)
        }

        // MARK: - Body

        var body: some View {
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: contentPadding) {
                        header
                        if model.showsPeers {
                            peersTile
                        }
                        masonry(
                            availableWidth: proxy.size.width - contentPadding * contentInsetColumns)
                    }
                    .padding(contentPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .animation(.default, value: model.status)
        }

        // MARK: - Header

        // The title and live status on the left, the routing switch on the right. The
        // switch is disabled until the peer is connected; the error message and the Set
        // Up or Retry action appear under the status when the status calls for them.
        private var header: some View {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: headerStackSpacing) {
                    Text(screenTitle)
                        .font(.largeTitle.bold())
                    Text(model.status.label)
                        .font(.title3)
                        .foregroundStyle(.secondary)
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
                Toggle(routeToggleTitle, isOn: model.routeTrafficBinding)
                    .toggleStyle(.switch)
                    .fixedSize()
                    .disabled(!model.status.allowsRouting)
            }
        }

        // MARK: - Masonry

        // Packs the tiles into balanced columns by row count, so a short tile does not
        // leave a gap the way an even grid would.
        private func masonry(availableWidth: CGFloat) -> some View {
            let columnCount = max(
                1,
                min(
                    maxColumns,
                    Int((availableWidth + gridSpacing) / (tileMinimumWidth + gridSpacing))
                )
            )
            let columns = distribute(tiles, into: columnCount)
            return HStack(alignment: .top, spacing: gridSpacing) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    VStack(spacing: gridSpacing) {
                        ForEach(column) { section in
                            tile(section)
                        }
                    }
                }
            }
        }

        private func distribute(
            _ sections: [ConnectionSection],
            into count: Int
        ) -> [[ConnectionSection]] {
            var columns = Array(repeating: [ConnectionSection](), count: count)
            var weights = Array(repeating: 0, count: count)
            for section in sections {
                let target = weights.indices.min { weights[$0] < weights[$1] } ?? 0
                columns[target].append(section)
                weights[target] += section.rows.count + sectionWeightOverhead
            }
            return columns
        }

        // MARK: - Peers

        // The discovered peers as a rounded tile, shown while discovery searches and
        // while a peer is unselected, so the user can pick the Mac to relay through.
        private var peersTile: some View {
            VStack(alignment: .leading, spacing: tileContentSpacing) {
                Text(RelayPeersView.title)
                    .font(.headline)
                VStack(spacing: tileRowSpacing) {
                    RelayPeersView(
                        peers: model.discoveredPeers,
                        selectedID: model.selectedPeerID
                    ) { id in
                        model.selectPeer(id: id)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(tilePadding)
            .background(
                RoundedRectangle(cornerRadius: tileCornerRadius, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
        }

        // MARK: - Tile

        // One rounded tile: the section title over its aligned rows.
        private func tile(_ section: ConnectionSection) -> some View {
            VStack(alignment: .leading, spacing: tileContentSpacing) {
                Text(section.title)
                    .font(.headline)
                VStack(spacing: tileRowSpacing) {
                    ForEach(section.rows) { row in
                        valueRow(row)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(tilePadding)
            .background(
                RoundedRectangle(cornerRadius: tileCornerRadius, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
        }

        // Label on the leading edge, value on the trailing edge, so every row in a tile
        // lines up. An unknown value is a redacted skeleton of fixed width.
        private func valueRow(_ row: ConnectionRow) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: valueRowSpacing) {
                Text(row.label)
                    .foregroundStyle(.secondary)
                Spacer(minLength: valueRowMinTrailing)
                if row.isPlaceholder {
                    Text(verbatim: skeletonValue)
                        .redacted(reason: .placeholder)
                } else {
                    Text(row.value)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
            .font(.subheadline)
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

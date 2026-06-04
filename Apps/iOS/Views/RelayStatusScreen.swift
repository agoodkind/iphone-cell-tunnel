//
//  RelayStatusScreen.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-02.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import SwiftUI

private let logger = CellTunnelLog.logger(category: .app)

// MARK: - Constants

private let screenTitle = "Cell Tunnel"
private let routeTrafficLabel = "Route traffic"
private let speedSectionTitle = "SPEED"
private let dataSectionTitle = "DATA"
private let bytesCountStyle = ByteCountFormatStyle(style: .file, spellsOutZero: false)
private let heroTitleSubtitleSpacing: CGFloat = 4

// MARK: - RelayStatusScreen

/// The one status screen, rendered the same on the iPhone and the Mac from a single
/// `RelayScreenModel`. Every surface is a stock SwiftUI component, so the Liquid
/// Glass look comes for free and the Mac adapts to its width through the same view
/// tree: a `List` whose `Section`s hold `LabeledContent` rows, a `Toggle` for the
/// one control, a plain title-and-subtitle hero in the connected states, and
/// `ContentUnavailableView` for the zero, connecting, and error states.
struct RelayStatusScreen: View {
    @Environment(RelayController.self) private var controller

    private var model: RelayScreenModel {
        RelayScreenModel(controller: controller)
    }

    // MARK: - Body

    var body: some View {
        let state = model.state
        NavigationStack {
            content(state: state)
                .navigationTitle(screenTitle)
                .navigationBarTitleDisplayMode(state.showsTunnelDetail ? .large : .inline)
        }
    }

    // The states with no tunnel detail render as a full-screen
    // `ContentUnavailableView`, the documented hero and zero-state component, under an
    // inline title so the empty state owns the screen rather than sitting below a
    // large left-aligned title. The states with detail render the hero plus the data
    // sections inside one `List` beneath the large title.
    @ViewBuilder private func content(state: RelayScreenState) -> some View {
        if state.showsTunnelDetail {
            detailList(state: state)
        } else {
            heroView
        }
    }

    // MARK: - Hero

    // The full-screen hero for the zero and edge states, with its SF Symbol label,
    // its description, and the optional action button wired to a controller verb.
    private var heroView: some View {
        ContentUnavailableView {
            Label(model.hero.title, systemImage: model.hero.symbolName)
        } description: {
            heroDescription
        } actions: {
            heroAction
        }
    }

    @ViewBuilder private var heroDescription: some View {
        if let subtitle = model.hero.subtitle {
            Text(subtitle)
        }
    }

    @ViewBuilder private var heroAction: some View {
        if let action = model.hero.action {
            Button(action.title) {
                perform(action)
            }
            .disabled(model.state.disablesControls)
        }
    }

    // MARK: - Detail list

    private func detailList(state: RelayScreenState) -> some View {
        List {
            heroSection
            if state.showsRouteSwitch {
                routeSection
            }
            if state.showsSpeed {
                speedSection
            }
            dataSection
            connectionSections
        }
        .listStyle(.insetGrouped)
    }

    // The connected-state hero: the status word and a one-line subtitle, leading
    // aligned and text only, with no icon.
    private var heroSection: some View {
        Section {
            VStack(alignment: .leading, spacing: heroTitleSubtitleSpacing) {
                Text(model.hero.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                if let subtitle = model.hero.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var routeSection: some View {
        Section {
            Toggle(routeTrafficLabel, isOn: routeBinding)
                .disabled(model.state.disablesControls)
        }
    }

    private var speedSection: some View {
        Section(speedSectionTitle) {
            valueRow(label: "Down", value: formattedRate(model.downloadMbps))
            valueRow(label: "Up", value: formattedRate(model.uploadMbps))
        }
    }

    private var dataSection: some View {
        Section(dataSectionTitle) {
            valueRow(label: "Total", value: formattedBytes(model.lifetimeTotalBytes))
        }
    }

    @ViewBuilder private var connectionSections: some View {
        ForEach(model.connectionSections) { section in
            Section(section.title) {
                ForEach(section.rows) { row in
                    valueRow(label: row.label, value: row.value)
                }
            }
        }
    }

    // One shared value row for every field: a stock `LabeledContent` whose value
    // wraps in full and is selectable to copy, with no truncation or custom layout.
    private func valueRow(label: String, value: String) -> some View {
        LabeledContent(label, value: value)
            .textSelection(.enabled)
    }

    // MARK: - Bindings

    private var routeBinding: Binding<Bool> {
        Binding(
            get: { model.routeTrafficEnabled },
            set: { newValue in
                Task {
                    await controller.setRouteTraffic(enabled: newValue)
                }
            }
        )
    }

    // MARK: - Actions

    private func perform(_ action: RelayHeroAction) {
        switch action {
        case .setUp:
            setUp()
        case .retry:
            retry()
        }
    }

    // Set Up brings the relay session up.
    private func setUp() {
        logger.notice("relay status screen set up requested")
        Task {
            await controller.start()
        }
    }

    private func retry() {
        logger.notice("relay status screen retry requested")
        Task {
            await controller.start()
        }
    }

    // MARK: - Formatting

    private func formattedRate(_ value: Double) -> String {
        String(format: "%.1f Mbps", value)
    }

    // ByteCountFormatStyle formats Int64, so the unsigned lifetime total is clamped
    // into the signed range before formatting; real byte totals stay well inside it.
    private func formattedBytes(_ value: UInt64) -> String {
        let clamped = Int64(min(value, UInt64(Int64.max)))
        return bytesCountStyle.format(clamped)
    }
}

// MARK: - Preview

#Preview {
    RelayStatusScreen()
        .environment(
            RelayController(
                backend: PreviewRelayBackend(),
                throughput: ThroughputCalculator(),
                lifetimeStore: LifetimeDataStore(),
                publicProbe: PublicAddressProbe()
            )
        )
}

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
private let secondaryGroupSpacing: CGFloat = 10

// MARK: - RelayStatusScreen

/// The one status screen, rendered the same on the iPhone and the Mac from a single
/// `RelayScreenModel`. Every surface is a stock SwiftUI component, so the Liquid
/// Glass look comes for free and the Mac adapts to its width through the same view
/// tree: a `List` whose `Section`s hold `LabeledContent` rows, a `Toggle` for the
/// one control, and `ContentUnavailableView` for the hero and every zero state.
struct RelayStatusScreen: View {
    let controller: RelayController

    private var model: RelayScreenModel {
        RelayScreenModel(controller: controller)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(screenTitle)
        }
    }

    // The states with no tunnel detail render as a full-screen
    // `ContentUnavailableView`, the documented hero and zero-state component. The
    // states with detail render the hero plus the data sections inside one `List`.
    @ViewBuilder private var content: some View {
        let state = model.state
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

    // The compact hero row that sits atop the detail list, a labeled state line so
    // the value is never unlabeled. A connected state never offers an action, so the
    // hero collapses to one `LabeledContent` row.
    private var heroSection: some View {
        Section {
            LabeledContent {
                Text(model.hero.title)
            } label: {
                Label(model.hero.title, systemImage: model.hero.symbolName)
                    .labelStyle(.iconOnly)
            }
            if let subtitle = model.hero.subtitle {
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
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
            LabeledContent("Down", value: formattedRate(model.downloadMbps))
            LabeledContent("Up", value: formattedRate(model.uploadMbps))
        }
    }

    private var dataSection: some View {
        Section(dataSectionTitle) {
            LabeledContent("Total", value: formattedBytes(model.lifetimeTotalBytes))
        }
    }

    @ViewBuilder private var connectionSections: some View {
        ForEach(model.connectionSections) { section in
            Section {
                ForEach(section.rows) { row in
                    LabeledContent(row.label, value: row.value)
                }
                if !section.secondaryRows.isEmpty {
                    Color.clear
                        .frame(height: secondaryGroupSpacing)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    ForEach(section.secondaryRows) { row in
                        LabeledContent(row.label, value: row.value)
                    }
                }
            } header: {
                connectionSectionHeader(section)
            }
        }
    }

    // The section header carries the title and its optional qualifier, both stock
    // `Text` inside the standard `Section` header, so `DEVICE Cellular` and
    // `RELAY WireGuard` read as one labeled header line.
    @ViewBuilder private func connectionSectionHeader(_ section: ConnectionSection) -> some View {
        if let qualifier = section.qualifier {
            LabeledContent(section.title, value: qualifier)
        } else {
            Text(section.title)
        }
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

    // KNOWN GAP: there is no app-side setup flow yet; the agent is configured out of
    // band via celltunnelctl and the iPhone via its tunnel manager. Set Up wires to
    // the closest existing capability, bringing the session up, until a real
    // configuration flow lands.
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
    RelayStatusScreen(controller: RelayController(backend: PreviewRelayBackend()))
}

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
private let dataSectionTitle = "Data"
private let currentSpeedSectionTitle = "Current Speed"
private let bytesCountStyle = ByteCountFormatStyle(style: .file, spellsOutZero: false)

// MARK: - RelayStatusScreen

/// The one status screen, rendered the same on the iPhone and the Mac from a single
/// `RelayScreenModel`. Every surface is a stock SwiftUI component, so the Liquid
/// Glass look comes for free and the Mac adapts to its width through the same view
/// tree. It is always the full list: a `List` whose `Section`s hold `LabeledContent`
/// rows, with the `Route traffic` toggle in the first section. A not-connected screen
/// is the same layout with placeholder values rather than a centered state.
struct RelayStatusScreen: View {
    @Environment(RelayController.self) private var controller

    private var model: RelayScreenModel {
        RelayScreenModel(controller: controller)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            detailList
                .navigationTitle(screenTitle)
                .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Detail list

    private var detailList: some View {
        List {
            statusSection
            dataSection
            if model.state.showsSpeed {
                currentSpeedSection
            }
            connectionSections
        }
        .listStyle(.insetGrouped)
        .animation(.default, value: model.state)
    }

    // The status section: the one routing switch, whose left label is the live
    // lifecycle status, plus the error message and the Set Up or Retry action as rows
    // when the state calls for them. The switch is disabled unless the peer link is
    // up, so routing cannot be requested with no peer to carry it.
    @ViewBuilder private var statusSection: some View {
        Section {
            Toggle(model.statusLabel, isOn: routeBinding)
                .disabled(model.state.disablesControls)
            if let message = model.errorMessage {
                Text(message)
            }
            if let action = model.heroAction {
                Button(action.title) {
                    perform(action)
                }
                .disabled(model.state.disablesControls)
            }
        }
    }

    // The Data section carries the lifetime byte totals: sent, received, and their
    // sum. The live rate lives in its own `Current Speed` section.
    private var dataSection: some View {
        Section(dataSectionTitle) {
            valueRow(label: "Transferred", value: formattedBytes(model.lifetimeTransferredBytes))
            valueRow(label: "Received", value: formattedBytes(model.lifetimeReceivedBytes))
            valueRow(label: "Total", value: formattedBytes(model.lifetimeTotalBytes))
        }
        .textCase(nil)
    }

    // The Current Speed section carries the live Up and Down rates, shown in the
    // routing state where the Mac's traffic crosses the tunnel.
    private var currentSpeedSection: some View {
        Section(currentSpeedSectionTitle) {
            valueRow(label: "Up", value: formattedRate(model.uploadMbps))
            valueRow(label: "Down", value: formattedRate(model.downloadMbps))
        }
        .textCase(nil)
    }

    @ViewBuilder private var connectionSections: some View {
        ForEach(model.connectionSections) { section in
            Section(section.title) {
                ForEach(section.rows) { row in
                    valueRow(label: row.label, value: row.value)
                }
            }
            .textCase(nil)
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
                lifetimeStore: LifetimeDataStore()
            )
        )
}

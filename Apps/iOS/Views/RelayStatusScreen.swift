//
//  RelayStatusScreen.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-02.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import SwiftUI

// MARK: - Constants

private let screenTitle = "Cell Tunnel"

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
            sections
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
            Toggle(model.statusLabel, isOn: model.routeTrafficBinding)
                .disabled(model.state.disablesControls)
            if let message = model.errorMessage {
                Text(message)
            }
            if let action = model.heroAction {
                Button(action.title) {
                    model.startSession()
                }
                .disabled(model.state.disablesControls)
            }
        }
    }

    // Every data-driven section in order, each a stock `Section` of value rows. The
    // model owns the section set, ordering, and formatting, so the iPhone list and the
    // Mac dashboard render the same content.
    @ViewBuilder private var sections: some View {
        ForEach(model.sections) { section in
            Section(section.title) {
                ForEach(section.rows) { row in
                    RelayValueRow(row: row)
                }
            }
            .textCase(nil)
        }
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

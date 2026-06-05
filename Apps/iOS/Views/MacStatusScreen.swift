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
    private let overviewTitle = "Overview"
    private let cardMinimumWidth: CGFloat = 260
    private let gridSpacing: CGFloat = 16

    // MARK: - MacStatusScreen

    /// The Mac status screen, a two-pane `NavigationSplitView`. The sidebar holds the
    /// live status and the routing switch, then a list of the Overview and each
    /// connection section. The detail shows the Overview as a card grid that reflows
    /// with the window width, or one selected section's rows in a wide pane. It reads
    /// the same `RelayScreenModel` the iPhone list does, so the two diverge only in
    /// layout, and a row or section with no value is already hidden by the model.
    struct MacStatusScreen: View {
        @Environment(RelayController.self) private var controller
        @State private var selection: String? = overviewTitle

        private var model: RelayScreenModel {
            RelayScreenModel(controller: controller)
        }

        // MARK: - Body

        var body: some View {
            NavigationSplitView {
                sidebar
                    .navigationTitle(screenTitle)
            } detail: {
                detail
                    .navigationTitle(selection ?? overviewTitle)
            }
            .animation(.default, value: model.state)
        }

        // MARK: - Sidebar

        // The status and routing switch at the top, then the Overview entry and one
        // entry per connection section that has a value. The switch is disabled unless
        // the peer link is up, the same rule the iPhone uses.
        private var sidebar: some View {
            List(selection: $selection) {
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
                Section {
                    Text(overviewTitle).tag(overviewTitle)
                    ForEach(model.connectionSections) { section in
                        Text(section.title).tag(section.title)
                    }
                }
            }
        }

        // MARK: - Detail

        // The Overview card grid, or the selected section's rows wide. A selection that
        // points at a section the model has since collapsed falls back to the Overview.
        @ViewBuilder private var detail: some View {
            if let section = selectedSection {
                sectionPane(section)
            } else {
                overview
            }
        }

        private var selectedSection: ConnectionSection? {
            guard let selection, selection != overviewTitle else {
                return nil
            }
            return model.sections.first { $0.title == selection }
        }

        // The Overview: one card per visible section, reflowing across the window width.
        private var overview: some View {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: cardMinimumWidth), spacing: gridSpacing)],
                    spacing: gridSpacing
                ) {
                    ForEach(model.sections) { section in
                        sectionCard(section)
                    }
                }
                .padding(gridSpacing)
            }
        }

        // One Overview card: the section title over its visible rows.
        private func sectionCard(_ section: ConnectionSection) -> some View {
            GroupBox(section.title) {
                VStack(spacing: 0) {
                    ForEach(section.rows) { row in
                        RelayValueRow(row: row)
                        if row.id != section.rows.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }

        // One selected section, its rows in a wide list pane.
        private func sectionPane(_ section: ConnectionSection) -> some View {
            List {
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

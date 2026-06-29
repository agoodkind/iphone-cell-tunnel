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
private let routeTrafficLabel = "Route traffic"

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
    .animation(.default, value: model.status)
  }

  // The status section: the live status word as its own row, separate from the
  // single Route traffic switch, so the status reports the current state rather than
  // labeling the switch. The switch is hidden with no peer, disabled with a
  // choose-a-config hint when a peer is connected but no config is active, and live
  // otherwise; the error message and the Retry action follow as rows when the status
  // calls for them.
  @ViewBuilder private var statusSection: some View {
    Section {
      Text(model.statusLabel)
      routeControlRows
      if let message = model.errorMessage {
        Text(message)
      }
      if model.heroAction == .retry {
        Button(RelayHeroAction.retry.title) {
          model.startSession()
        }
      }
    }
  }

  // The Route traffic switch row driven by the derived presentation: absent when
  // hidden, a disabled switch with the hint beneath it when a config must be chosen,
  // and a live switch with a connect spinner when enabled.
  @ViewBuilder private var routeControlRows: some View {
    switch model.routeControl.presentation {
    case .hidden:
      EmptyView()
    case .disabled(let hint):
      routeToggleRow(isEnabled: false)
      Text(hint)
        .font(.caption)
        .foregroundStyle(.secondary)
    case .enabled:
      routeToggleRow(isEnabled: true)
    }
  }

  /// The Route traffic switch row, live when `isEnabled` and showing a spinner while
  /// the relay is connecting, so the iPhone presents the same single control as the Mac.
  private func routeToggleRow(isEnabled: Bool) -> some View {
    HStack {
      Text(routeTrafficLabel)
      Spacer()
      if isEnabled, model.isConnecting {
        ProgressView()
      }
      Toggle(routeTrafficLabel, isOn: model.routeTrafficBinding)
        .labelsHidden()
        .disabled(!isEnabled)
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

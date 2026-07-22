//
//  ConfigLibraryView.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Constants

private let configLibraryTitle = "Configs"
private let configLibraryNewTitle = "New"
private let configLibraryImportTitle = "Import…"
private let configLibraryEditTitle = "Edit"
private let configLibraryRenameTitle = "Rename"
private let configLibraryDeleteTitle = "Delete"
private let configLibraryActionsAccessibilityLabel = "Config actions"
private let configLibraryRenameSheetTitle = "Rename Config"
private let configLibraryRenameFieldTitle = "Name"
private let configLibraryRenameConfirmTitle = "Rename"
private let configLibraryCancelTitle = "Cancel"
private let configLibraryEmptyMessage =
  "No configs yet. Add a new one or import a WireGuard config."
private let configLibraryActionsSymbol = "ellipsis.circle"
private let configLibraryActiveAccessibilityLabel = "Active config"
private let configLibrarySectionSpacing: CGFloat = 12
private let configLibraryHeaderSpacing: CGFloat = 10
private let configLibraryActionSpacing: CGFloat = 8
private let configLibraryDividerOutset: CGFloat = 8
private let configLibraryContentTypes: [UTType] = [
  UTType(filenameExtension: "conf") ?? .data,
  .text,
  .plainText,
]

// MARK: - ActiveConfigSheet

/// The single sheet the config library presents, either editing an existing config or
/// composing a new one. Driving both through one `sheet(item:)` keeps the view from
/// stacking two competing sheet presentations, which wedges modal presentation on Mac
/// Catalyst and freezes the window.
private enum ActiveConfigSheet: Identifiable {
  case create
  case edit(TunnelConfigSummary)

  var id: String {
    switch self {
    case .create:
      return "create"
    case .edit(let config):
      return "edit-\(config.id.uuidString)"
    }
  }
}

// MARK: - ConfigLibraryView

/// Presents the stored WireGuard configs inside the shared masonry tile, the same rounded
/// `secondarySystemBackground` card the status tiles use, with the `Configs` title inside
/// it. The configs are stacked rows separated by dividers; each row is a leading checkmark
/// on the active config, the name, and a trailing native `Menu` of Edit, Rename, and a
/// destructive Delete. Tapping a row activates that config. Import and New sit below the
/// card, outside the grey tile. New opens the editor on a blank config and creates it on
/// save without stealing the active selection.
struct ConfigLibraryView: View {
  @Environment(RelayController.self) private var controller
  @State private var isImportingConfig = false
  @State private var activeSheet: ActiveConfigSheet?
  @State private var isRenaming = false
  @State private var renamingID: UUID?
  @State private var renameText = ""

  // MARK: - Body

  // Each modal presentation lives on its own view so the library never stacks a sheet, a
  // file importer, and an alert on one node; on Mac Catalyst that stack wedges the window
  // when the file importer opens. The editor and new-config flows share one `sheet(item:)`,
  // and the file importer sits on the Import button in `actions`.
  var body: some View {
    VStack(alignment: .leading, spacing: configLibrarySectionSpacing) {
      card
      actions
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .sheet(item: $activeSheet) { sheet in
      switch sheet {
      case .edit(let config):
        ConfigEditorView(config: config)
      case .create:
        ConfigEditorView(config: nil)
      }
    }
    .alert(configLibraryRenameSheetTitle, isPresented: $isRenaming) {
      renameAlertContent
    }
  }

  // MARK: - Card

  // The grey tile holds the title and the config rows, matching the status tiles.
  private var card: some View {
    VStack(alignment: .leading, spacing: configLibraryHeaderSpacing) {
      Text(configLibraryTitle)
        .font(.headline)
      content
    }
    .dashboardTile()
  }

  // MARK: - Rows

  @ViewBuilder private var content: some View {
    let configs = controller.configLibrary
    if configs.isEmpty {
      Text(configLibraryEmptyMessage)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      VStack(spacing: 0) {
        ForEach(Array(configs.enumerated()), id: \.element.id) { index, config in
          if index > 0 {
            Divider()
              .padding(.horizontal, -configLibraryDividerOutset)
          }
          configRow(config)
        }
      }
    }
  }

  private func configRow(_ config: TunnelConfigSummary) -> some View {
    SelectableRow(
      isSelected: config.id == controller.activeConfigID,
      title: config.name,
      selectionAccessibilityLabel: configLibraryActiveAccessibilityLabel,
      onTap: { controller.activateConfig(id: config.id) },
      trailing: { rowMenu(config) }
    )
  }

  // The trailing native menu using the system ellipsis-circle symbol. Delete carries the
  // destructive role, so it renders red at the foot of the menu.
  private func rowMenu(_ config: TunnelConfigSummary) -> some View {
    Menu {
      Button(configLibraryEditTitle) {
        activeSheet = .edit(config)
      }
      Button(configLibraryRenameTitle) {
        startRename(config)
      }
      Divider()
      Button(configLibraryDeleteTitle, role: .destructive) {
        controller.deleteConfig(id: config.id)
      }
    } label: {
      Image(systemName: configLibraryActionsSymbol)
        .font(.title3)
        .foregroundStyle(.secondary)
    }
    .menuIndicator(.hidden)
    .buttonStyle(.plain)
    .tint(.secondary)
    .accessibilityLabel(configLibraryActionsAccessibilityLabel)
  }

  // MARK: - Actions

  // Import and New sit below the card, outside the grey tile, like the System Settings
  // Other button. New opens a blank editor; the config is created on save.
  private var actions: some View {
    HStack(spacing: configLibraryActionSpacing) {
      Spacer(minLength: 0)
      Button(configLibraryImportTitle) {
        isImportingConfig = true
      }
      .buttonStyle(.bordered)
      .fileImporter(
        isPresented: $isImportingConfig,
        allowedContentTypes: configLibraryContentTypes,
        allowsMultipleSelection: false
      ) { result in
        handleImport(result)
      }
      Button(configLibraryNewTitle) {
        activeSheet = .create
      }
      .buttonStyle(.bordered)
    }
  }

  // MARK: - Rename

  @ViewBuilder private var renameAlertContent: some View {
    TextField(configLibraryRenameFieldTitle, text: $renameText)
    Button(configLibraryCancelTitle, role: .cancel) {
      // Dismiss the rename alert without changing the name.
    }
    Button(configLibraryRenameConfirmTitle) {
      confirmRename()
    }
  }

  private func startRename(_ config: TunnelConfigSummary) {
    renamingID = config.id
    renameText = config.name
    isRenaming = true
  }

  private func confirmRename() {
    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let id = renamingID, !name.isEmpty else {
      return
    }
    controller.renameConfig(id: id, name: name)
  }

  // MARK: - Import

  private func handleImport(_ result: Result<[URL], Error>) {
    switch result {
    case .success(let urls):
      guard let url = urls.first else {
        return
      }
      let name = url.deletingPathExtension().lastPathComponent
      controller.importConfig(url: url, name: name)
    case .failure:
      break
    }
  }
}

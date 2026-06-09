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
private let configLibraryImportTitle = "Import .conf"
private let configLibraryTileCornerRadius: CGFloat = 14
private let configLibraryTileContentSpacing: CGFloat = 12
private let configLibraryTileRowSpacing: CGFloat = 10
private let configLibraryTilePadding: CGFloat = 16
private let configLibraryRowSpacing: CGFloat = 12
private let configLibraryEmptyTitle = "No configs"
private let configLibraryRenameTitle = "Rename Config"
private let configLibraryNameTitle = "Name"
private let configLibraryActivateTitle = "Activate"
private let configLibraryRenameActionTitle = "Rename"
private let configLibraryDeleteTitle = "Delete"
private let configLibraryCancelTitle = "Cancel"
private let configLibraryActiveAccessibilityLabel = "Active config"
private let configLibraryEditAccessibilityLabel = "Edit config"
private let configLibraryMoreAccessibilityLabel = "Config actions"
private let configLibraryContentTypes: [UTType] = [
  UTType(filenameExtension: "conf") ?? .data,
  .text,
  .plainText,
]

// MARK: - ConfigLibraryView

/// Lists stored WireGuard configs and presents import, activation, edit, rename,
/// and delete actions from one rounded SwiftUI tile.
struct ConfigLibraryView: View {
  @Environment(RelayController.self) private var controller
  @State private var isImportingConfig = false
  @State private var editingConfig: StoredTunnelConfig?
  @State private var renamingConfig: StoredTunnelConfig?
  @State private var isRenameAlertPresented = false
  @State private var renameText = ""

  // MARK: - Body

  var body: some View {
    VStack(alignment: .leading, spacing: configLibraryTileContentSpacing) {
      Text(configLibraryTitle)
        .font(.headline)
      VStack(spacing: configLibraryTileRowSpacing) {
        configRows
        importButton
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(configLibraryTilePadding)
    .background(
      RoundedRectangle(cornerRadius: configLibraryTileCornerRadius, style: .continuous)
        .fill(.regularMaterial)
    )
    .sheet(item: $editingConfig) { config in
      ConfigEditorView(config: config)
    }
    .alert(configLibraryRenameTitle, isPresented: $isRenameAlertPresented) {
      TextField(configLibraryNameTitle, text: $renameText)
      Button(configLibraryCancelTitle, role: .cancel) {
        resetRenameState()
      }
      Button(configLibraryRenameActionTitle) {
        commitRename()
      }
    }
    .fileImporter(
      isPresented: $isImportingConfig,
      allowedContentTypes: configLibraryContentTypes,
      allowsMultipleSelection: false
    ) { result in
      handleImport(result)
    }
  }

  // MARK: - Rows

  @ViewBuilder private var configRows: some View {
    let configs = controller.listConfigs()
    if configs.isEmpty {
      Text(configLibraryEmptyTitle)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      ForEach(configs) { config in
        configRow(config)
      }
    }
  }

  private func configRow(_ config: StoredTunnelConfig) -> some View {
    HStack(alignment: .center, spacing: configLibraryRowSpacing) {
      activeIndicator(for: config)
      Text(config.name)
        .font(.subheadline)
        .lineLimit(1)
      Spacer(minLength: configLibraryRowSpacing)
      Button {
        editingConfig = config
      } label: {
        Image(systemName: "pencil")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(configLibraryEditAccessibilityLabel)
      actionsMenu(for: config)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private func activeIndicator(for config: StoredTunnelConfig) -> some View {
    if config.id == controller.activeConfigID {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.tint)
        .accessibilityLabel(configLibraryActiveAccessibilityLabel)
    }
  }

  private var importButton: some View {
    Button {
      isImportingConfig = true
    } label: {
      Label(configLibraryImportTitle, systemImage: "square.and.arrow.down")
    }
    .buttonStyle(.bordered)
  }

  // MARK: - Actions

  private func actionsMenu(for config: StoredTunnelConfig) -> some View {
    Menu {
      Button {
        controller.activateConfig(id: config.id)
      } label: {
        Label(configLibraryActivateTitle, systemImage: "checkmark.circle")
      }
      Button {
        beginRename(config)
      } label: {
        Label(configLibraryRenameActionTitle, systemImage: "text.cursor")
      }
      Button(role: .destructive) {
        controller.deleteConfig(id: config.id)
      } label: {
        Label(configLibraryDeleteTitle, systemImage: "trash")
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .accessibilityLabel(configLibraryMoreAccessibilityLabel)
    }
  }

  private func beginRename(_ config: StoredTunnelConfig) {
    renamingConfig = config
    renameText = config.name
    isRenameAlertPresented = true
  }

  private func commitRename() {
    guard let config = renamingConfig else {
      return
    }
    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      resetRenameState()
      return
    }
    controller.renameConfig(id: config.id, name: name)
    resetRenameState()
  }

  private func resetRenameState() {
    renamingConfig = nil
    renameText = ""
    isRenameAlertPresented = false
  }

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

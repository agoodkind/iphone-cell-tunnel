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
private let configLibraryImportTitle = "Import"
private let configLibraryEmptyTitle =
  "No configs yet. Import a WireGuard config to get started."
private let configLibraryTileCornerRadius: CGFloat = 14
private let configLibraryRowCornerRadius: CGFloat = 9
private let configLibraryTilePadding: CGFloat = 16
private let configLibraryHeaderSpacing: CGFloat = 12
private let configLibraryListSpacing: CGFloat = 4
private let configLibraryRowSpacing: CGFloat = 12
private let configLibraryRowHorizontalPadding: CGFloat = 10
private let configLibraryRowVerticalPadding: CGFloat = 9
private let configLibraryEmptySpacing: CGFloat = 16
private let configLibrarySelectedRowOpacity: Double = 0.1
private let configLibraryActiveSymbol = "checkmark.circle.fill"
private let configLibraryInactiveSymbol = "circle"
private let configLibraryImportSymbol = "square.and.arrow.down"
private let configLibraryEditSymbol = "pencil"
private let configLibraryDeleteSymbol = "trash"
private let configLibraryActiveAccessibilityLabel = "Active config"
private let configLibraryInactiveAccessibilityLabel = "Inactive config"
private let configLibraryEditAccessibilityLabel = "Edit config"
private let configLibraryDeleteAccessibilityLabel = "Delete config"
private let configLibraryContentTypes: [UTType] = [
  UTType(filenameExtension: "conf") ?? .data,
  .text,
  .plainText,
]

// MARK: - ConfigLibraryView

/// Lists stored WireGuard configs in one rounded tile and presents import,
/// activation, edit, and delete actions. The active config carries a filled
/// checkmark and a faint tint background; tapping a row's name area activates it.
struct ConfigLibraryView: View {
  @Environment(RelayController.self) private var controller
  @State private var isImportingConfig = false
  @State private var editingConfig: TunnelConfigSummary?

  // MARK: - Body

  var body: some View {
    VStack(alignment: .leading, spacing: configLibraryHeaderSpacing) {
      header
      configRows
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(configLibraryTilePadding)
    .background(
      RoundedRectangle(cornerRadius: configLibraryTileCornerRadius, style: .continuous)
        .fill(Color(uiColor: .secondarySystemBackground))
    )
    .sheet(item: $editingConfig) { config in
      ConfigEditorView(config: config)
    }
    .fileImporter(
      isPresented: $isImportingConfig,
      allowedContentTypes: configLibraryContentTypes,
      allowsMultipleSelection: false
    ) { result in
      handleImport(result)
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(configLibraryTitle)
        .font(.headline)
      Spacer(minLength: configLibraryRowSpacing)
      // The empty state carries its own primary Import button, so the header
      // button shows only once configs exist to avoid a duplicate import icon.
      if !controller.configLibrary.isEmpty {
        importButton
          .buttonStyle(.bordered)
      }
    }
  }

  // MARK: - Rows

  @ViewBuilder private var configRows: some View {
    let configs = controller.configLibrary
    if configs.isEmpty {
      emptyState
    } else {
      VStack(spacing: configLibraryListSpacing) {
        ForEach(configs) { config in
          configRow(config)
        }
      }
    }
  }

  private func configRow(_ config: TunnelConfigSummary) -> some View {
    let isActive = config.id == controller.activeConfigID
    return HStack(alignment: .center, spacing: configLibraryRowSpacing) {
      Button {
        controller.activateConfig(id: config.id)
      } label: {
        rowLabel(config, isActive: isActive)
      }
      .buttonStyle(.plain)
      editButton(config)
      deleteButton(config)
    }
    .padding(.horizontal, configLibraryRowHorizontalPadding)
    .padding(.vertical, configLibraryRowVerticalPadding)
    .background(rowBackground(isActive: isActive))
  }

  private func rowLabel(_ config: TunnelConfigSummary, isActive: Bool) -> some View {
    HStack(spacing: configLibraryRowSpacing) {
      activeIndicator(isActive: isActive)
      Text(config.name)
        .font(.subheadline)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .contentShape(.rect)
  }

  private func activeIndicator(isActive: Bool) -> some View {
    Image(systemName: isActive ? configLibraryActiveSymbol : configLibraryInactiveSymbol)
      .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
      .accessibilityLabel(
        isActive
          ? configLibraryActiveAccessibilityLabel
          : configLibraryInactiveAccessibilityLabel
      )
  }

  @ViewBuilder private func rowBackground(isActive: Bool) -> some View {
    if isActive {
      RoundedRectangle(cornerRadius: configLibraryRowCornerRadius, style: .continuous)
        .fill(.tint.opacity(configLibrarySelectedRowOpacity))
    }
  }

  private func editButton(_ config: TunnelConfigSummary) -> some View {
    Button {
      editingConfig = config
    } label: {
      Image(systemName: configLibraryEditSymbol)
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(configLibraryEditAccessibilityLabel)
  }

  private func deleteButton(_ config: TunnelConfigSummary) -> some View {
    Button(role: .destructive) {
      controller.deleteConfig(id: config.id)
    } label: {
      Image(systemName: configLibraryDeleteSymbol)
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(configLibraryDeleteAccessibilityLabel)
  }

  // MARK: - Import

  private var importButton: some View {
    Button {
      isImportingConfig = true
    } label: {
      Label(configLibraryImportTitle, systemImage: configLibraryImportSymbol)
    }
  }

  // MARK: - Empty state

  private var emptyState: some View {
    VStack(spacing: configLibraryEmptySpacing) {
      Text(configLibraryEmptyTitle)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      importButton
        .buttonStyle(.borderedProminent)
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: - Actions

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

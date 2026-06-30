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
private let configLibraryNewConfigName = "New Config"
private let configLibraryActiveSymbol = "checkmark"
private let configLibraryActionsSymbol = "ellipsis.circle"
private let configLibraryActiveAccessibilityLabel = "Active config"
private let configLibraryTileCornerRadius: CGFloat = 14
private let configLibraryTilePadding: CGFloat = 16
private let configLibrarySectionSpacing: CGFloat = 12
private let configLibraryHeaderSpacing: CGFloat = 10
private let configLibraryRowSpacing: CGFloat = 10
private let configLibraryRowVerticalPadding: CGFloat = 8
private let configLibraryActionSpacing: CGFloat = 8
private let configLibraryIconWidth: CGFloat = 16
private let configLibraryKeyByteCount = 32
private let configLibraryContentTypes: [UTType] = [
  UTType(filenameExtension: "conf") ?? .data,
  .text,
  .plainText,
]

// MARK: - ConfigLibraryView

/// Presents the stored WireGuard configs inside the shared masonry tile, the same rounded
/// `secondarySystemBackground` card the status tiles use, with the `Configs` title inside
/// it. The configs are stacked rows separated by dividers; each row is a leading checkmark
/// on the active config, the name, and a trailing native `Menu` of Edit, Rename, and a
/// destructive Delete. Tapping a row activates that config. Import and New sit at the foot
/// as standard buttons.
struct ConfigLibraryView: View {
  @Environment(RelayController.self) private var controller
  @State private var isImportingConfig = false
  @State private var editingConfig: TunnelConfigSummary?
  @State private var isRenaming = false
  @State private var renamingID: UUID?
  @State private var renameText = ""

  // MARK: - Body

  var body: some View {
    VStack(alignment: .leading, spacing: configLibrarySectionSpacing) {
      Text(configLibraryTitle)
        .font(.headline)
      content
      actions
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
    .alert(configLibraryRenameSheetTitle, isPresented: $isRenaming) {
      renameAlertContent
    }
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
          }
          configRow(config)
        }
      }
    }
  }

  private func configRow(_ config: TunnelConfigSummary) -> some View {
    let isActive = config.id == controller.activeConfigID
    return HStack(spacing: configLibraryRowSpacing) {
      Image(systemName: configLibraryActiveSymbol)
        .foregroundStyle(.tint)
        .opacity(isActive ? 1 : 0)
        .accessibilityLabel(configLibraryActiveAccessibilityLabel)
        .accessibilityHidden(!isActive)
        .frame(width: configLibraryIconWidth)
      Text(config.name)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: configLibraryRowSpacing)
      rowMenu(config)
    }
    .padding(.vertical, configLibraryRowVerticalPadding)
    .contentShape(.rect)
    .onTapGesture {
      controller.activateConfig(id: config.id)
    }
  }

  // The trailing native menu using the system ellipsis-circle symbol. Delete carries the
  // destructive role, so it renders red at the foot of the menu.
  private func rowMenu(_ config: TunnelConfigSummary) -> some View {
    Menu {
      Button(configLibraryEditTitle) {
        editingConfig = config
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

  private var actions: some View {
    HStack(spacing: configLibraryActionSpacing) {
      Spacer(minLength: 0)
      Button(configLibraryImportTitle) {
        isImportingConfig = true
      }
      .buttonStyle(.bordered)
      Button(configLibraryNewTitle) {
        createNewConfig()
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

  // MARK: - Import and create

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

  // Seeds a parseable, unique placeholder config and hands it to the create path. The
  // agent validates on import and rejects unparseable text, and dedups by normalized
  // text, so the placeholder carries a fresh random key to pass validation and stay
  // distinct across repeated New actions. The user opens Edit to fill in real values.
  private func createNewConfig() {
    let key = Self.randomWireGuardKeyBase64()
    let template = """
      [Interface]
      PrivateKey = \(key)
      Address = 10.0.0.2/32

      [Peer]
      PublicKey = \(key)
      Endpoint = example.com:51820
      AllowedIPs = 0.0.0.0/0
      """
    controller.importConfig(name: configLibraryNewConfigName, text: template)
  }

  /// A fresh 32-byte base64 value shaped like a WireGuard key, unique per call so the
  /// placeholder both parses and defeats the agent's text dedup.
  private static func randomWireGuardKeyBase64() -> String {
    var bytes = [UInt8](repeating: 0, count: configLibraryKeyByteCount)
    for index in bytes.indices {
      bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
    }
    return Data(bytes).base64EncodedString()
  }
}

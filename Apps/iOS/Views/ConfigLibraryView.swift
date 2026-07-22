//
//  ConfigLibraryView.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

#if targetEnvironment(macCatalyst)
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
  private let configLibraryImportFailureTitle = "Unable to Import Config"
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
    @State private var presentation = ConfigLibraryPresentation.idle
    @State private var activeImportRequestID: UUID?
    @State private var renameText = ""

    // MARK: - Body

    var body: some View {
      VStack(alignment: .leading, spacing: configLibrarySectionSpacing) {
        card
        actions
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .sheet(item: editorPresentationBinding) { editorPresentation in
        editor(for: editorPresentation)
      }
      .alert(
        alertTitle,
        isPresented: alertPresentationBinding,
        presenting: presentation.alertPresentation
      ) { alertPresentation in
        alertActions(for: alertPresentation)
      } message: { alertPresentation in
        alertMessage(for: alertPresentation)
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
          presentation.presentEdit(config)
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
          presentation.presentImport()
        }
        .buttonStyle(.bordered)
        .disabled(activeImportRequestID != nil)
        .fileImporter(
          isPresented: importPresentationBinding,
          allowedContentTypes: configLibraryContentTypes,
          allowsMultipleSelection: false
        ) { result in
          handleImport(result)
        }
        Button(configLibraryNewTitle) {
          presentation.presentCreate()
        }
        .buttonStyle(.bordered)
      }
    }

    // MARK: - Rename

    private func startRename(_ config: TunnelConfigSummary) {
      renameText = config.name
      presentation.presentRename(config)
    }

    private func confirmRename() {
      let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard case .renaming(let config) = presentation, !name.isEmpty else {
        return
      }
      controller.renameConfig(id: config.id, name: name)
      presentation.dismiss()
    }

    // MARK: - Import

    private func handleImport(_ result: Result<[URL], Error>) {
      switch result {
      case .success(let urls):
        presentation.completeImportSelection()
        guard let url = urls.first else {
          return
        }
        let name = url.deletingPathExtension().lastPathComponent
        guard activeImportRequestID == nil else {
          return
        }
        let requestID = UUID()
        activeImportRequestID = requestID
        Task {
          do {
            try await controller.importConfig(url: url, name: name)
            completeImport(requestID: requestID, error: nil)
          } catch {
            completeImport(requestID: requestID, error: error)
          }
        }
      case .failure(let error):
        presentation.failImport(message: error.localizedDescription)
      }
    }

    private func completeImport(requestID: UUID, error: Error?) {
      guard activeImportRequestID == requestID else {
        return
      }
      activeImportRequestID = nil
      if let error {
        presentation.completeImportFailure(message: error.localizedDescription)
      }
    }

    // MARK: - Presentation bindings

    private var editorPresentationBinding: Binding<ConfigLibraryPresentation?> {
      Binding(
        get: { presentation.editorPresentation },
        set: { newPresentation in
          if let newPresentation {
            presentation = newPresentation
          } else {
            presentation.dismiss()
          }
        }
      )
    }

    private var importPresentationBinding: Binding<Bool> {
      Binding(
        get: { presentation.isImporting },
        set: { isPresented in
          if isPresented {
            presentation.presentImport()
          } else {
            presentation.dismissImport()
          }
        }
      )
    }

    private var alertPresentationBinding: Binding<Bool> {
      Binding(
        get: { presentation.alertPresentation != nil },
        set: { isPresented in
          if !isPresented {
            presentation.dismiss()
          }
        }
      )
    }

    private var alertTitle: String {
      switch presentation {
      case .renaming:
        configLibraryRenameSheetTitle
      case .importFailure:
        configLibraryImportFailureTitle
      case .idle, .importing, .creating, .editing:
        ""
      }
    }

    @ViewBuilder private func editor(
      for presentation: ConfigLibraryPresentation
    ) -> some View {
      switch presentation {
      case .creating:
        ConfigEditorView(config: nil)
      case .editing(let config):
        ConfigEditorView(config: config)
      case .idle, .importing, .renaming, .importFailure:
        EmptyView()
      }
    }

    @ViewBuilder private func alertActions(
      for presentation: ConfigLibraryPresentation
    ) -> some View {
      switch presentation {
      case .renaming:
        TextField(configLibraryRenameFieldTitle, text: $renameText)
        Button(configLibraryCancelTitle, role: .cancel) {
          self.presentation.dismiss()
        }
        Button(configLibraryRenameConfirmTitle) {
          confirmRename()
        }
      case .importFailure:
        Button(configLibraryCancelTitle, role: .cancel) {
          self.presentation.dismiss()
        }
      case .idle, .importing, .creating, .editing:
        EmptyView()
      }
    }

    @ViewBuilder private func alertMessage(
      for presentation: ConfigLibraryPresentation
    ) -> some View {
      switch presentation {
      case .importFailure(let message):
        Text(message)
      case .idle, .importing, .creating, .editing, .renaming:
        EmptyView()
      }
    }
  }

#endif

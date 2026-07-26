//
//  ConfigEditorView.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

#if targetEnvironment(macCatalyst)
  import CellTunnelCore
  import Foundation
  import SwiftUI

  // MARK: - Constants

  private let configEditorCancelTitle = "Cancel"
  private let configEditorSaveTitle = "Save"
  private let configEditorNameSectionTitle = "Name"
  private let configEditorConfigSectionTitle = "Configuration"
  private let configEditorNamePlaceholder = "Config Name"
  private let configEditorNewTitle = "New Config"
  private let configEditorNewConfigName = "New Config"
  private let configEditorMinWidth: CGFloat = 460
  private let configEditorMinHeight: CGFloat = 520
  private let configEditorIdealWidth: CGFloat = 640
  private let configEditorIdealHeight: CGFloat = 720
  private let configEditorDefaultParentWidth: CGFloat = 760
  private let configEditorDefaultParentHeight: CGFloat = 520
  private let configEditorContentInset: CGFloat = 20
  private let configEditorBlockPadding: CGFloat = 16
  private let configEditorBlockCornerRadius: CGFloat = 10
  private let configEditorSectionSpacing: CGFloat = 16
  private let configEditorLabelSpacing: CGFloat = 6
  private let configEditorKeyByteCount = 32
  private let configEditorNewTemplate = """
    [Interface]
    PrivateKey = %@
    Address = 10.0.0.2/32

    [Peer]
    PublicKey = %@
    Endpoint = example.com:51820
    AllowedIPs = 0.0.0.0/0
    """

  // MARK: - ConfigEditorView

  /// Edits one stored WireGuard config in a sheet. The agent owns the config text, so
  /// the editor fetches it on demand from the summary's id rather than holding it. It
  /// presents the plain `ConfigEditView` as soon as it loads. It does not use a `Form`:
  /// on Mac Catalyst a `Form` is a list, and a `TextEditor` hosted in a list cell stops
  /// accepting input and resets its scroll, so the editor is laid out directly here. Save
  /// stays disabled until the text has loaded, so a failed fetch cannot overwrite the
  /// stored config with empty text.
  struct ConfigEditorView: View {
    /// The config being edited, or nil when composing a new config.
    let config: TunnelConfigSummary?
    let parentContentSize: CGSize
    @Environment(RelayController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var loaded = false
    @State private var newName = ""
    @State private var didAttemptLoad = false

    // MARK: - Body

    var body: some View {
      NavigationStack {
        editorContent
          .navigationTitle(principalTitle)
          .navigationBarTitleDisplayMode(.inline)
          .task {
            await loadConfigOnce()
          }
          .toolbar {
            toolbarContent
          }
      }
      .frame(
        minWidth: configEditorMinWidth,
        idealWidth: configEditorIdealWidth,
        maxWidth: .infinity,
        minHeight: configEditorMinHeight,
        idealHeight: configEditorIdealHeight,
        maxHeight: .infinity
      )
      .cellTunnelAccessibilityIdentifier(.configEditor)
      .frame(width: editorContentSize.width, height: editorContentSize.height)
    }

    // MARK: - Content

    /// The name block over the configuration block, both filling the sheet width, with
    /// the configuration block expanding to take the remaining height so a long config
    /// has room to scroll.
    private var editorContent: some View {
      VStack(alignment: .leading, spacing: configEditorSectionSpacing) {
        VStack(alignment: .leading, spacing: configEditorLabelSpacing) {
          sectionLabel(configEditorNameSectionTitle)
          nameField
            .modifier(ConfigBlockBackground())
        }
        VStack(alignment: .leading, spacing: configEditorLabelSpacing) {
          sectionLabel(configEditorConfigSectionTitle)
          configBody
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .modifier(ConfigBlockBackground())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      .padding(configEditorContentInset)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var editorContentSize: CGSize {
      CGSize(
        width: max(
          configEditorMinWidth,
          parentContentSize.width - configEditorDefaultParentWidth + configEditorIdealWidth
        ),
        height: max(
          configEditorMinHeight,
          parentContentSize.height - configEditorDefaultParentHeight + configEditorIdealHeight
        )
      )
    }

    private func sectionLabel(_ title: String) -> some View {
      Text(title)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    /// The name row: an editable field for a new config, or the fixed name for an
    /// existing one, which is renamed elsewhere rather than in the editor.
    @ViewBuilder private var nameField: some View {
      if config == nil {
        TextField(configEditorNamePlaceholder, text: $newName)
          .textFieldStyle(.plain)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Text(config?.name ?? "")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }

    /// The configuration body exposes the editable draft only after its text has loaded.
    @ViewBuilder private var configBody: some View {
      if loaded {
        ConfigEditView(text: $text)
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }

    // MARK: - Title

    /// The principal toolbar label: the config name when editing an existing config, or
    /// the typed new name.
    private var principalTitle: String {
      if let config {
        return config.name
      }
      return newName.isEmpty ? configEditorNewTitle : newName
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
      ToolbarItem(placement: .cancellationAction) {
        Button(configEditorCancelTitle) {
          dismiss()
        }
        .fixedSize()
      }
      ToolbarItem(placement: .confirmationAction) {
        Button(configEditorSaveTitle) {
          saveAndDismiss()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!loaded)
      }
    }

    // MARK: - Actions

    /// Loads the config text exactly once so a re-run cannot overwrite an in-progress
    /// draft. A new config seeds the starter template and enables Save immediately.
    private func loadConfigOnce() async {
      if didAttemptLoad {
        return
      }
      didAttemptLoad = true
      if let config {
        // Gate `loaded` on a real fetch so a nil load leaves Save disabled and cannot
        // overwrite the stored config with empty text.
        if let loadedText = await controller.loadConfigText(id: config.id) {
          text = loadedText
          loaded = true
        }
      } else {
        text = Self.newConfigTemplate()
        loaded = true
      }
    }

    private func saveAndDismiss() {
      if let config {
        controller.saveConfigEdit(id: config.id, text: text)
      } else {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        controller.createConfig(
          name: name.isEmpty ? configEditorNewConfigName : name,
          text: text
        )
      }
      dismiss()
    }

    /// A starter WireGuard config for a new entry, carrying a generated key so it parses,
    /// with placeholder values the user replaces.
    private static func newConfigTemplate() -> String {
      let key = randomWireGuardKeyBase64()
      return String(format: configEditorNewTemplate, key, key)
    }

    /// A fresh 32-byte base64 value shaped like a WireGuard key, unique per call so the
    /// starter config parses and stays distinct across repeated New actions.
    private static func randomWireGuardKeyBase64() -> String {
      var bytes = [UInt8](repeating: 0, count: configEditorKeyByteCount)
      for index in bytes.indices {
        bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
      }
      return Data(bytes).base64EncodedString()
    }
  }

  // MARK: - ConfigBlockBackground

  /// The shared grouped-section look for the editor's name and configuration blocks: the
  /// shared inner padding over a rounded `secondarySystemBackground` fill, so the sheet
  /// keeps its familiar card sections without a `Form`.
  private struct ConfigBlockBackground: ViewModifier {
    func body(content: Content) -> some View {
      content
        .padding(configEditorBlockPadding)
        .background(
          RoundedRectangle(cornerRadius: configEditorBlockCornerRadius, style: .continuous)
            .fill(Color(uiColor: .secondarySystemBackground))
        )
    }
  }

#endif

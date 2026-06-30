//
//  ConfigEditorView.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import SwiftUI

// MARK: - Constants

private let configEditorCancelTitle = "Cancel"
private let configEditorSaveTitle = "Save"
private let configEditorEditTitle = "Edit"
private let configEditorDoneTitle = "Done"
private let configEditorRevealSymbol = "eye"
private let configEditorHideSymbol = "eye.slash"
private let configEditorRevealAccessibilityLabel = "Reveal secret value"
private let configEditorHideAccessibilityLabel = "Hide secret value"
private let configEditorMaskedAccessibilityLabel = "Hidden secret value"
private let configEditorMaskBulletCount = 14
private let configEditorMaskBullets = String(
  repeating: "\u{2022}",
  count: configEditorMaskBulletCount
)
private let configEditorNameSectionTitle = "Name"
private let configEditorConfigSectionTitle = "Configuration"
private let configEditorMinWidth: CGFloat = 460
private let configEditorMinHeight: CGFloat = 520
private let configEditorTextMinHeight: CGFloat = 240
private let configEditorLineSpacing: CGFloat = 2
private let configEditorRevealSpacing: CGFloat = 8
private let configEditorEmptyLinePlaceholder = " "
private let configEditorMonospace: Font = .system(.body, design: .monospaced)
private let configEditorNamePlaceholder = "Config Name"
private let configEditorNewTitle = "New Config"
private let configEditorNewConfigName = "New Config"
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

// MARK: - ConfigEditorLineKind

/// Classifies one config line so the read view can color it. Secret lines carry
/// the label prefix (through `=`) and the value so the value can be masked or
/// revealed separately.
private enum ConfigEditorLineKind {
  case comment
  case plain
  case secret(label: String, value: String)
  case sectionHeader
}

// MARK: - ConfigEditorLine

/// One parsed config line, keyed by its position so `ForEach` stays stable.
private struct ConfigEditorLine: Identifiable {
  let id: Int
  let text: String
  let kind: ConfigEditorLineKind
}

// MARK: - ConfigEditorView

/// Edits one stored WireGuard config. The agent owns the config text, so the
/// editor fetches it on demand from the summary's id rather than holding it. The
/// default read view renders the config line by line with light syntax coloring
/// and masks `PrivateKey` and `PresharedKey` values behind bullets, each with an
/// inline reveal control that shows that one value in place without exposing the
/// others. A separate Edit toggle swaps the read view for a plain monospace
/// editor. Save is disabled until the text has loaded so a failed fetch cannot
/// overwrite the stored config with empty text.
struct ConfigEditorView: View {
  /// The config being edited, or nil when composing a new config.
  let config: TunnelConfigSummary?
  @Environment(RelayController.self) private var controller
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @State private var loaded = false
  @State private var editing = false
  @State private var newName = ""
  @State private var heavyReady = false
  @State private var revealedLineIDs: Set<Int> = []

  // MARK: - Body

  var body: some View {
    NavigationStack {
      Form {
        Section(configEditorNameSectionTitle) {
          if config == nil {
            TextField(configEditorNamePlaceholder, text: $newName)
          } else {
            Text(config?.name ?? "")
              .foregroundStyle(.secondary)
          }
        }
        Section(configEditorConfigSectionTitle) {
          editorBody
        }
      }
      .formStyle(.grouped)
      .navigationTitle(principalTitle)
      .navigationBarTitleDisplayMode(.inline)
      .task {
        if let config {
          text = await controller.loadConfigText(id: config.id) ?? ""
        } else {
          text = Self.newConfigTemplate()
          editing = true
        }
        loaded = true
        heavyReady = true
      }
      .toolbar {
        toolbarContent
      }
    }
    .frame(minWidth: configEditorMinWidth, minHeight: configEditorMinHeight)
  }

  // MARK: - Title

  /// The principal toolbar label: the config name when editing, or the typed new name.
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
    if config != nil {
      ToolbarItem(placement: .primaryAction) {
        Button(editing ? configEditorDoneTitle : configEditorEditTitle) {
          editing.toggle()
        }
      }
    }
    ToolbarItem(placement: .confirmationAction) {
      Button(configEditorSaveTitle) {
        saveAndDismiss()
      }
      .buttonStyle(.borderedProminent)
      .disabled(!loaded)
    }
  }

  // MARK: - Body content

  /// Shows the masked read view by default and a plain editor while editing.
  @ViewBuilder private var editorBody: some View {
    if editing {
      if heavyReady {
        TextEditor(text: $text)
          .font(configEditorMonospace)
          .frame(minHeight: configEditorTextMinHeight)
      } else {
        Text(text)
          .font(configEditorMonospace)
          .foregroundStyle(.secondary)
          .frame(
            maxWidth: .infinity,
            minHeight: configEditorTextMinHeight,
            alignment: .topLeading
          )
      }
    } else {
      maskedReadView
    }
  }

  private var maskedReadView: some View {
    VStack(alignment: .leading, spacing: configEditorLineSpacing) {
      ForEach(parsedLines) { line in
        lineRow(line)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Line rows

  /// Renders one parsed line: section headers and comments are tinted or dimmed,
  /// secret lines mask their value and carry an inline reveal control, and every
  /// other line stays primary.
  @ViewBuilder private func lineRow(_ line: ConfigEditorLine) -> some View {
    switch line.kind {
    case .sectionHeader:
      coloredLine(line.text, style: AnyShapeStyle(.tint))
    case .comment:
      coloredLine(line.text, style: AnyShapeStyle(.secondary))
    case .plain:
      coloredLine(line.text, style: AnyShapeStyle(.primary))
    case let .secret(label, value):
      secretRow(id: line.id, label: label, value: value)
    }
  }

  private func coloredLine(_ text: String, style: AnyShapeStyle) -> some View {
    Text(text.isEmpty ? configEditorEmptyLinePlaceholder : text)
      .font(configEditorMonospace)
      .foregroundStyle(style)
      .frame(maxWidth: .infinity, alignment: .leading)
      .textSelection(.enabled)
  }

  /// Renders one secret line with its label prefix in primary, the value either
  /// masked behind a fixed-width bullet run or shown in place, and an inline
  /// toggle keyed to this line so other secrets stay hidden.
  private func secretRow(id: Int, label: String, value: String) -> some View {
    let isRevealed = revealedLineIDs.contains(id)
    return HStack(spacing: 0) {
      Text("\(label) ")
        .foregroundStyle(.primary)
      secretValue(value, isRevealed: isRevealed)
      Spacer(minLength: configEditorRevealSpacing)
      revealButton(id: id, isRevealed: isRevealed)
    }
    .font(configEditorMonospace)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func secretValue(_ value: String, isRevealed: Bool) -> some View {
    if isRevealed {
      Text(value)
        .foregroundStyle(.primary)
        .textSelection(.enabled)
    } else {
      Text(configEditorMaskBullets)
        .foregroundStyle(.secondary)
        .accessibilityLabel(configEditorMaskedAccessibilityLabel)
    }
  }

  private func revealButton(id: Int, isRevealed: Bool) -> some View {
    Button {
      toggleReveal(id: id)
    } label: {
      Image(systemName: isRevealed ? configEditorHideSymbol : configEditorRevealSymbol)
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(
      isRevealed ? configEditorHideAccessibilityLabel : configEditorRevealAccessibilityLabel
    )
  }

  // MARK: - Actions

  private func toggleReveal(id: Int) {
    if revealedLineIDs.contains(id) {
      revealedLineIDs.remove(id)
    } else {
      revealedLineIDs.insert(id)
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

  // MARK: - Parsing

  private var parsedLines: [ConfigEditorLine] {
    let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)
    return rawLines.enumerated().map { index, raw in
      ConfigEditorLine(id: index, text: String(raw), kind: Self.classify(String(raw)))
    }
  }

  /// Maps a raw line to its display kind, splitting secret lines into the label
  /// prefix and the value so the value can be masked.
  private static func classify(_ line: String) -> ConfigEditorLineKind {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("[") {
      return .sectionHeader
    }
    if trimmed.hasPrefix("#") {
      return .comment
    }
    if let parts = secretParts(in: line) {
      return .secret(label: parts.label, value: parts.value)
    }
    return .plain
  }

  /// Splits a `PrivateKey`/`PresharedKey` line into the label prefix through `=`
  /// and the trailing value, or returns nil when the line is not a masked secret.
  private static func secretParts(in line: String) -> (label: String, value: String)? {
    let trimmed = line.drop { $0 == " " || $0 == "\t" }
    let lowered = trimmed.lowercased()
    guard lowered.hasPrefix("privatekey") || lowered.hasPrefix("presharedkey") else {
      return nil
    }
    guard let equalsIndex = line.firstIndex(of: "=") else {
      return nil
    }
    let label = String(line[...equalsIndex])
    let valueStart = line.index(after: equalsIndex)
    let value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
    return (label, value)
  }
}

//
//  ConfigEditorView.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import SwiftUI

// MARK: - Constants

private let configEditorCancelTitle = "Cancel"
private let configEditorSaveTitle = "Save"
private let configEditorRevealSymbol = "eye"
private let configEditorRevealAccessibilityLabel = "Reveal secret and edit"
private let configEditorMaskedAccessibilityLabel = "Hidden secret value"
private let configEditorMaskBulletCount = 14
private let configEditorMaskBullets = String(
  repeating: "\u{2022}",
  count: configEditorMaskBulletCount
)
private let configEditorTitleSpacing: CGFloat = 16
private let configEditorLineSpacing: CGFloat = 2
private let configEditorRevealSpacing: CGFloat = 8
private let configEditorEmptyLinePlaceholder = " "
private let configEditorMonospace: Font = .system(.body, design: .monospaced)

// MARK: - ConfigEditorLineKind

/// Classifies one config line so the read view can color it. Secret lines carry
/// the label prefix (through `=`) so the value can be masked separately.
private enum ConfigEditorLineKind {
  case comment
  case plain
  case secret(label: String)
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
/// inline reveal control. Revealing unlocks a plain monospace editor so the real
/// key is never lost behind the mask. Save is disabled until the text has loaded
/// so a failed fetch cannot overwrite the stored config with empty text.
struct ConfigEditorView: View {
  let config: TunnelConfigSummary
  @Environment(RelayController.self) private var controller
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @State private var loaded = false
  @State private var revealed = false

  init(config: TunnelConfigSummary) {
    self.config = config
  }

  // MARK: - Body

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: configEditorTitleSpacing) {
        title
        editorBody
      }
      .padding()
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .task {
        text = await controller.loadConfigText(id: config.id) ?? ""
        loaded = true
      }
      .toolbar {
        toolbarContent
      }
    }
  }

  // MARK: - Title

  private var title: some View {
    Text(config.name)
      .font(.largeTitle)
      .bold()
      .lineLimit(1)
      .truncationMode(.tail)
  }

  // MARK: - Toolbar

  @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
    ToolbarItem(placement: .cancellationAction) {
      Button(configEditorCancelTitle) {
        dismiss()
      }
    }
    ToolbarItem(placement: .principal) {
      Text(config.name)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    ToolbarItem(placement: .confirmationAction) {
      Button(configEditorSaveTitle) {
        controller.saveConfigEdit(id: config.id, text: text)
        dismiss()
      }
      .buttonStyle(.borderedProminent)
      .disabled(!loaded)
    }
  }

  // MARK: - Body content

  /// Shows the masked read view by default and a plain editor once revealed.
  @ViewBuilder private var editorBody: some View {
    if revealed {
      TextEditor(text: $text)
        .font(configEditorMonospace)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else {
      maskedReadView
    }
  }

  private var maskedReadView: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: configEditorLineSpacing) {
        ForEach(parsedLines) { line in
          lineRow(line)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
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
    case .secret(let label):
      secretRow(label: label)
    }
  }

  private func coloredLine(_ text: String, style: AnyShapeStyle) -> some View {
    Text(text.isEmpty ? configEditorEmptyLinePlaceholder : text)
      .font(configEditorMonospace)
      .foregroundStyle(style)
      .frame(maxWidth: .infinity, alignment: .leading)
      .textSelection(.enabled)
  }

  private func secretRow(label: String) -> some View {
    HStack(spacing: 0) {
      Text("\(label) ")
        .foregroundStyle(.primary)
      Text(configEditorMaskBullets)
        .foregroundStyle(.secondary)
        .accessibilityLabel(configEditorMaskedAccessibilityLabel)
      Spacer(minLength: configEditorRevealSpacing)
      revealButton
    }
    .font(configEditorMonospace)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var revealButton: some View {
    Button {
      revealed = true
    } label: {
      Image(systemName: configEditorRevealSymbol)
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(configEditorRevealAccessibilityLabel)
  }

  // MARK: - Parsing

  private var parsedLines: [ConfigEditorLine] {
    let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)
    return rawLines.enumerated().map { index, raw in
      ConfigEditorLine(id: index, text: String(raw), kind: Self.classify(String(raw)))
    }
  }

  /// Maps a raw line to its display kind without exposing any secret value.
  private static func classify(_ line: String) -> ConfigEditorLineKind {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("[") {
      return .sectionHeader
    }
    if trimmed.hasPrefix("#") {
      return .comment
    }
    if let label = secretLabel(in: line) {
      return .secret(label: label)
    }
    return .plain
  }

  /// Returns the label prefix through `=` for a `PrivateKey`/`PresharedKey` line,
  /// or nil when the line is not a masked secret.
  private static func secretLabel(in line: String) -> String? {
    let trimmed = line.drop { $0 == " " || $0 == "\t" }
    let lowered = trimmed.lowercased()
    guard lowered.hasPrefix("privatekey") || lowered.hasPrefix("presharedkey") else {
      return nil
    }
    guard let equalsIndex = line.firstIndex(of: "=") else {
      return nil
    }
    return String(line[...equalsIndex])
  }
}

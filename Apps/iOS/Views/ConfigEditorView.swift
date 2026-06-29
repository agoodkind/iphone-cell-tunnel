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
private let configEditorTitleSpacing: CGFloat = 16
private let configEditorLineSpacing: CGFloat = 2
private let configEditorRevealSpacing: CGFloat = 8
private let configEditorEmptyLinePlaceholder = " "
private let configEditorMonospace: Font = .system(.body, design: .monospaced)

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
  let config: TunnelConfigSummary
  @Environment(RelayController.self) private var controller
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @State private var loaded = false
  @State private var editing = false
  @State private var revealedLineIDs: Set<Int> = []

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
    ToolbarItem(placement: .primaryAction) {
      Button(editing ? configEditorDoneTitle : configEditorEditTitle) {
        editing.toggle()
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
    controller.saveConfigEdit(id: config.id, text: text)
    dismiss()
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

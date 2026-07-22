//
//  ConfigReadView.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-17.
//  Copyright © 2026, all rights reserved.
//

#if targetEnvironment(macCatalyst)
  import CellTunnelCore
  import SwiftUI

  // MARK: - Constants

  private let configReadMonospace: Font = .system(.body, design: .monospaced)
  private let configReadMaskBulletCount = 14
  private let configReadMaskBullets = String(
    repeating: "\u{2022}",
    count: configReadMaskBulletCount
  )
  private let configReadRevealSymbol = "eye"
  private let configReadHideSymbol = "eye.slash"
  private let configReadRevealAccessibilityLabel = "Reveal secret value"
  private let configReadHideAccessibilityLabel = "Hide secret value"
  private let configReadMaskedAccessibilityLabel = "Hidden secret value"
  private let configReadLineSpacing: CGFloat = 2
  private let configReadRevealSpacing: CGFloat = 8
  private let configReadEmptyLinePlaceholder = " "

  // MARK: - ConfigReadView

  /// Shows a stored WireGuard config for reading, one line at a time with light syntax
  /// coloring. `PrivateKey` and `PresharedKey` values are masked behind bullets, and
  /// each secret line carries an inline reveal control that shows only that one value,
  /// so opening one secret never exposes the others. The lines scroll on their own, so
  /// this view fills whatever space its container gives it without needing a `Form`.
  struct ConfigReadView: View {
    /// The full config text to display. Classification and masking are derived from it.
    let text: String
    /// The ids of the secret lines currently revealed, reset each time the view appears.
    @State private var revealedLineIDs: Set<Int> = []

    // MARK: - Body

    var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: configReadLineSpacing) {
          ForEach(ConfigLineSyntax.classify(text)) { line in
            lineRow(line)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }

    // MARK: - Line rows

    /// Renders one classified line: section headers and comments are tinted or dimmed,
    /// secret lines mask their value behind an inline reveal control, and every other
    /// line stays primary.
    @ViewBuilder private func lineRow(_ line: ConfigLine) -> some View {
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
      Text(text.isEmpty ? configReadEmptyLinePlaceholder : text)
        .font(configReadMonospace)
        .foregroundStyle(style)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    /// Renders one secret line: the label prefix in primary, the value either masked
    /// behind a fixed-width bullet run or shown in place, and an inline toggle keyed to
    /// this line so other secrets stay hidden.
    private func secretRow(id: Int, label: String, value: String) -> some View {
      let isRevealed = revealedLineIDs.contains(id)
      return HStack(spacing: 0) {
        Text("\(label) ")
          .foregroundStyle(.primary)
        secretValue(value, isRevealed: isRevealed)
        Spacer(minLength: configReadRevealSpacing)
        revealButton(id: id, isRevealed: isRevealed)
      }
      .font(configReadMonospace)
      .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func secretValue(_ value: String, isRevealed: Bool) -> some View {
      if isRevealed {
        Text(value)
          .foregroundStyle(.primary)
          .textSelection(.enabled)
      } else {
        Text(configReadMaskBullets)
          .foregroundStyle(.secondary)
          .accessibilityLabel(configReadMaskedAccessibilityLabel)
      }
    }

    private func revealButton(id: Int, isRevealed: Bool) -> some View {
      Button {
        toggleReveal(id: id)
      } label: {
        Image(systemName: isRevealed ? configReadHideSymbol : configReadRevealSymbol)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(
        isRevealed ? configReadHideAccessibilityLabel : configReadRevealAccessibilityLabel
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
  }

#endif

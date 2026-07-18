//
//  ConfigLineSyntax.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-17.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - ConfigLineKind

/// Classifies one config line for display. A secret line carries its label prefix
/// (through `=`) and its value split apart, so the value can be masked or revealed
/// on its own while the label stays visible.
public enum ConfigLineKind: Equatable, Sendable {
  case comment
  case plain
  case secret(label: String, value: String)
  case sectionHeader
}

// MARK: - ConfigLine

/// One classified config line, keyed by its position so a `ForEach` over the lines
/// stays stable as the reveal state changes.
public struct ConfigLine: Identifiable, Equatable, Sendable {
  public let id: Int
  public let text: String
  public let kind: ConfigLineKind

  /// Creates a classified config line at `id` with its raw `text` and display `kind`.
  public init(id: Int, text: String, kind: ConfigLineKind) {
    self.id = id
    self.text = text
    self.kind = kind
  }
}

// MARK: - ConfigLineSyntax

/// Splits a wg-quick config into display-classified lines. This is the one place
/// that decides what a line is for the editor's read view: a `[section]` header, a
/// `#` comment, a masked `PrivateKey`/`PresharedKey` secret with its value split
/// off, or a plain line. It never logs or transforms the config; it only labels it.
public enum ConfigLineSyntax {
  /// The secret-carrying keys whose value is masked in the read view.
  private static let secretKeyPrefixes = ["privatekey", "presharedkey"]

  /// Classifies every line of `text`, preserving blank lines so the rendered line
  /// count matches the source. Each line's `id` is its zero-based position.
  public static func classify(_ text: String) -> [ConfigLine] {
    let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)
    var lines: [ConfigLine] = []
    for (index, rawLine) in rawLines.enumerated() {
      let lineText = String(rawLine)
      lines.append(ConfigLine(id: index, text: lineText, kind: kind(of: lineText)))
    }
    return lines
  }

  // MARK: - Classification

  /// Maps one raw line to its display kind, splitting a secret line into the label
  /// prefix and the value so the value can be masked separately.
  private static func kind(of line: String) -> ConfigLineKind {
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

  /// Splits a `PrivateKey`/`PresharedKey` line into the label prefix through `=` and
  /// the trimmed trailing value, or returns nil when the line is not a masked secret.
  private static func secretParts(in line: String) -> (label: String, value: String)? {
    let leadingTrimmed = line.drop { $0 == " " || $0 == "\t" }
    let lowered = leadingTrimmed.lowercased()
    let isSecretKey = secretKeyPrefixes.contains { prefix in
      lowered.hasPrefix(prefix)
    }
    guard isSecretKey else {
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

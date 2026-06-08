//
//  ConfigSecretMasking.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-07.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - ConfigSecretMasking

/// Masks the `PrivateKey` value in a wg-quick config for display, so the editor
/// can show the config without printing the secret. It only rewrites the value to
/// the right of `PrivateKey =`; every other line passes through unchanged. The
/// original text is never logged.
public enum ConfigSecretMasking {
  private static let maskedPlaceholder = ".............."

  /// Returns the text with any `PrivateKey` value replaced by a fixed mask.
  public static func maskingPrivateKey(in text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let rewritten = lines.map { line -> Substring in
      maskedLine(from: line) ?? line
    }
    return rewritten.joined(separator: "\n")
  }

  private static func maskedLine(from line: Substring) -> Substring? {
    let trimmed = line.drop { $0 == " " || $0 == "\t" }
    guard trimmed.lowercased().hasPrefix("privatekey") else {
      return nil
    }
    guard let equalsIndex = line.firstIndex(of: "=") else {
      return nil
    }
    let prefix = line[...equalsIndex]
    return Substring("\(prefix) \(maskedPlaceholder)")
  }
}

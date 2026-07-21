//
//  ConfigEditView.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-17.
//  Copyright © 2026, all rights reserved.
//

import SwiftUI

// MARK: - Constants

private let configEditMonospace: Font = .system(.body, design: .monospaced)

// MARK: - ConfigEditView

/// Edits the raw config text in a plain monospace `TextEditor`. It lives outside any
/// `Form` or `List` on purpose: on Mac Catalyst a `TextEditor` hosted in a list cell
/// stops accepting keystrokes and resets its scroll, so the editor is given its own
/// space here where it types and scrolls normally. It fills whatever space its
/// container provides and scrolls its own content.
struct ConfigEditView: View {
  /// The config text being edited, bound to the owning editor's state.
  @Binding var text: String

  // MARK: - Body

  var body: some View {
    TextEditor(text: $text)
      .font(configEditMonospace)
      .scrollContentBackground(.hidden)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

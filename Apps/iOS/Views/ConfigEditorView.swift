//
//  ConfigEditorView.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import SwiftUI

// MARK: - ConfigEditorView

/// Edits one stored WireGuard config. The PrivateKey is masked until revealed, so
/// the secret is not shown by default, and editing is enabled only when revealed
/// so the real key is never lost behind the mask.
struct ConfigEditorView: View {
  let config: StoredTunnelConfig
  @Environment(RelayController.self) private var controller
  @Environment(\.dismiss) private var dismiss
  @State private var text: String
  @State private var revealed = false

  init(config: StoredTunnelConfig) {
    self.config = config
    _text = State(initialValue: config.text)
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading) {
        Toggle("Reveal private key", isOn: $revealed)
        if revealed {
          TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
        } else {
          ScrollView {
            Text(ConfigSecretMasking.maskingPrivateKey(in: text))
              .font(.system(.body, design: .monospaced))
              .frame(maxWidth: .infinity, alignment: .leading)
              .textSelection(.enabled)
          }
        }
      }
      .padding()
      .navigationTitle(config.name)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            controller.saveConfigEdit(id: config.id, text: text)
            dismiss()
          }
        }
      }
    }
  }
}

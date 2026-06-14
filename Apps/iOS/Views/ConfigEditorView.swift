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

/// Edits one stored WireGuard config. The agent owns the config text, so the
/// editor fetches it on demand from the summary's id rather than holding it, then
/// masks the PrivateKey until revealed so the secret is not shown by default and
/// editing is enabled only when revealed so the real key is never lost behind the
/// mask. Save is disabled until the text has loaded so a failed fetch cannot
/// overwrite the stored config with empty text.
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

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading) {
        Toggle("Reveal private key", isOn: $revealed)
          .disabled(!loaded)
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
      .task {
        text = await controller.loadConfigText(id: config.id) ?? ""
        loaded = true
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            controller.saveConfigEdit(id: config.id, text: text)
            dismiss()
          }
          .disabled(!loaded)
        }
      }
    }
  }
}

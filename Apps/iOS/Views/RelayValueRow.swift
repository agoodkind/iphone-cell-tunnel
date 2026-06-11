//
//  RelayValueRow.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-05.
//  Copyright © 2026, all rights reserved.
//

import SwiftUI

// MARK: - Constants

/// The gap between the label line and the value lines of a stacked multiline row.
private let stackedRowSpacing: CGFloat = 2

// MARK: - RelayValueRow

/// One label-and-value line, a stock `LabeledContent` whose value wraps in full and
/// is selectable to copy. A multiline value always renders stacked, the label on top
/// and the value lines beneath it, so every multiline row reads top-justified instead
/// of letting `LabeledContent` pick a width-dependent vertically centered layout. The
/// iPhone list and the Mac dashboard both render rows through this, so the row
/// presentation lives in one place.
struct RelayValueRow: View {
  let row: ConnectionRow

  var body: some View {
    if row.value.contains("\n") {
      VStack(alignment: .leading, spacing: stackedRowSpacing) {
        Text(row.label)
        Text(row.value)
          .foregroundStyle(.secondary)
      }
      .textSelection(.enabled)
    } else {
      LabeledContent(row.label, value: row.value)
        .textSelection(.enabled)
    }
  }
}

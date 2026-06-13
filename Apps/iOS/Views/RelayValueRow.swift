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
/// A value-width string drawn only as a redacted skeleton, so its characters never
/// show; it sets the placeholder bar's width.
private let skeletonValue = "000.000.000.000"

// MARK: - RelayValueRow

/// One label-and-value line, the single row view the iPhone list and the Mac dashboard
/// both render, so the row presentation lives in one place and the two screens cannot
/// drift. A value that has not arrived renders as a fixed-width redacted skeleton bar;
/// the iPhone never reaches that case because it drops placeholder rows before they
/// render, so the skeleton is the Mac's not-connected look. A multiline value renders
/// stacked, the label on top and the value lines beneath it, the iOS Settings language
/// for long values, so a multi-address row reads top-justified instead of letting
/// `LabeledContent` pick a width-dependent vertically centered layout. A single-line
/// value renders inline through `LabeledContent`, the label leading and the value
/// trailing.
struct RelayValueRow: View {
  let row: ConnectionRow

  var body: some View {
    if row.isPlaceholder {
      LabeledContent(row.label) {
        Text(verbatim: skeletonValue)
          .redacted(reason: .placeholder)
      }
    } else if row.value.contains("\n") {
      VStack(alignment: .leading, spacing: stackedRowSpacing) {
        Text(row.label)
        Text(row.value)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .textSelection(.enabled)
    } else {
      LabeledContent(row.label, value: row.value)
        .textSelection(.enabled)
    }
  }
}

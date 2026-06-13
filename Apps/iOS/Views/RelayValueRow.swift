//
//  RelayValueRow.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-05.
//  Copyright © 2026, all rights reserved.
//

import SwiftUI

// MARK: - Constants

/// The gap between the label line and the value lines of a stacked row.
private let stackedRowSpacing: CGFloat = 2
/// The minimum gap between the label and a value sharing one line.
private let inlineGap: CGFloat = 12
/// A value-width string drawn only as a redacted skeleton, so its characters never
/// show; it sets the placeholder bar's width.
private let skeletonValue = "000.000.000.000"

// MARK: - RelayValueRow

/// The single row view every status row renders through, on the iPhone list and the
/// Mac dashboard alike, so the row presentation lives in one place and the two screens
/// cannot drift. The row owns its full width and its own layout, so no container sets a
/// row width or alignment. One rule, the `Interface IPv6` rule: a value short enough to
/// share the line sits inline with the label leading and the value trailing; a value
/// too long, or one with several lines, drops to its own line(s) below the label.
/// `ViewThatFits` picks the inline layout first and falls back to the stacked layout,
/// and the inline texts are fixed-size so the row relocates the value rather than
/// truncating it. A not-yet-arrived value renders as a redacted skeleton bar (only the
/// Mac reaches that case, since the iPhone drops placeholder rows before they render).
struct RelayValueRow: View {
  let row: ConnectionRow

  var body: some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .textSelection(.enabled)
  }

  @ViewBuilder private var content: some View {
    if row.value.contains("\n") {
      stacked
    } else {
      ViewThatFits(in: .horizontal) {
        inline
        stacked
      }
    }
  }

  // Label leading, value trailing, on one line. The texts take their full width, so
  // when the pair would not fit `ViewThatFits` relocates to `stacked` instead of the
  // value truncating.
  private var inline: some View {
    HStack(spacing: inlineGap) {
      Text(row.label)
        .fixedSize(horizontal: true, vertical: false)
      Spacer(minLength: inlineGap)
      value
        .fixedSize(horizontal: true, vertical: false)
    }
  }

  // Label on top, value beneath, left-aligned: the layout for any value that cannot
  // share the line, including a multi-line value.
  private var stacked: some View {
    VStack(alignment: .leading, spacing: stackedRowSpacing) {
      Text(row.label)
      value
    }
  }

  @ViewBuilder private var value: some View {
    if row.isPlaceholder {
      Text(verbatim: skeletonValue)
        .redacted(reason: .placeholder)
        .foregroundStyle(.secondary)
    } else {
      Text(row.value)
        .foregroundStyle(.secondary)
    }
  }
}

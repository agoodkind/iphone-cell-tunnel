//
//  SelectableRow.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-30.
//  Copyright © 2026, all rights reserved.
//

import SwiftUI

// MARK: - Constants

/// The SF Symbol marking the selected row.
private let selectionRowSymbol = "checkmark"
/// The fixed leading width reserved for the selection checkmark, held so selected and
/// unselected rows align.
private let selectionRowIconWidth: CGFloat = 16
/// The horizontal gap between the checkmark, the title, and the trailing content.
private let selectionRowSpacing: CGFloat = 10
/// The vertical inset on each selectable row.
private let selectionRowVerticalPadding: CGFloat = 8

// MARK: - SelectableRow

/// One tappable list row carrying a leading checkmark shown only when selected, a
/// truncating title, and a trailing slot for a menu or nothing. The Configs library and
/// the Peers roster both render through it so their selection rows cannot drift.
struct SelectableRow<Trailing: View>: View {
  /// Whether this row is the selected one, which shows the checkmark.
  let isSelected: Bool
  /// The row's primary label.
  let title: String
  /// The accessibility label spoken for the selection checkmark.
  let selectionAccessibilityLabel: String
  /// The action run when the row is tapped.
  let onTap: () -> Void
  /// The trailing content, such as a menu, placed after the spacer.
  @ViewBuilder let trailing: () -> Trailing

  // MARK: - Body

  var body: some View {
    HStack(spacing: selectionRowSpacing) {
      Image(systemName: selectionRowSymbol)
        .foregroundStyle(.tint)
        .opacity(isSelected ? 1 : 0)
        .accessibilityLabel(selectionAccessibilityLabel)
        .accessibilityHidden(!isSelected)
        .frame(width: selectionRowIconWidth)
      Text(title)
        .font(.subheadline)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: selectionRowSpacing)
      trailing()
    }
    .padding(.vertical, selectionRowVerticalPadding)
    .contentShape(.rect)
    .onTapGesture(perform: onTap)
  }
}

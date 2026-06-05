//
//  RelayValueRow.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-05.
//  Copyright © 2026, all rights reserved.
//

import SwiftUI

// MARK: - RelayValueRow

/// One label-and-value line, a stock `LabeledContent` whose value wraps in full and
/// is selectable to copy. The iPhone list and the Mac dashboard both render rows
/// through this, so the row presentation lives in one place.
struct RelayValueRow: View {
    let row: ConnectionRow

    var body: some View {
        LabeledContent(row.label, value: row.value)
            .textSelection(.enabled)
    }
}

//
//  ToolError.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026, all rights reserved.
//

import Foundation

enum ToolError: Error, CustomStringConvertible {
  case failure(String)
  case usage(String)

  var description: String {
    switch self {
    case .failure(let message):
      return message
    case .usage(let message):
      return message
    }
  }
}

// MARK: - CommandResult

struct CommandResult {
  let status: Int32
  let output: String
}

//
//  AgentTunnelControllerError.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation

// MARK: - AgentTunnelControllerError

/// The errors the agent tunnel controller raises, each mapped to a control error
/// code and a human-readable message for the control response.
enum AgentTunnelControllerError: LocalizedError {
  case missingServerEndpoint
  case sessionUnavailable

  var errorCode: TunnelControlErrorCode {
    switch self {
    case .missingServerEndpoint:
      return .missingWireGuardConfigPath
    case .sessionUnavailable:
      return .runtimeStartFailure
    }
  }

  var message: String {
    switch self {
    case .missingServerEndpoint:
      return "wireguard config has no parseable peer Endpoint"
    case .sessionUnavailable:
      return "tunnel provider session is unavailable"
    }
  }

  var errorDescription: String? {
    message
  }
}

//
//  AgentControlListenerError.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-09.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - AgentControlListenerError

/// The control listener's failure cases: a missing handshake acknowledgement, a
/// connection or listener failure with its detail, and an error the peer reported
/// over the link.
enum AgentControlListenerError: LocalizedError {
  case acknowledgeMissing
  case connectionFailed(String)
  case listenerFailed(String)
  case remoteError(RemoteErrorPayload)

  struct RemoteErrorPayload: Sendable, Equatable {
    var code: String
    var message: String
  }

  var errorDescription: String? {
    switch self {
    case .acknowledgeMissing:
      return "control listener did not receive set-server-endpoint acknowledgement"
    case .connectionFailed(let detail):
      return "control listener connection failed: \(detail)"
    case .listenerFailed(let detail):
      return "control listener failed: \(detail)"
    case .remoteError(let payload):
      return "control listener remote error code=\(payload.code) message=\(payload.message)"
    }
  }
}

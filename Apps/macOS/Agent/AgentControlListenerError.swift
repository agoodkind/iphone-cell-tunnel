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
  /// The peer did not acknowledge the expected request during the handshake.
  case acknowledgeMissing
  /// The control connection failed with a string detail from the receive path.
  case connectionFailed(String)
  /// The TCP listener failed with a string detail from Network.framework.
  case listenerFailed(String)
  /// The peer sent an error payload over the control wire.
  case remoteError(RemoteErrorPayload)

  /// The decoded peer error payload carried over the control wire.
  struct RemoteErrorPayload: Sendable, Equatable {
    /// The peer-supplied error code.
    var code: String
    /// The peer-supplied error message.
    var message: String
  }

  /// The user-readable error description surfaced by `LocalizedError`.
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

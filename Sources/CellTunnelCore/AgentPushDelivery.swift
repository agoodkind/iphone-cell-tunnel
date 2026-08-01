//
//  AgentPushDelivery.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-01.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation
import Synchronization

private let logger = CellTunnelLog.logger(category: .daemon)

// MARK: - AgentPushDelivery

/// Carries what the agent sends on its own initiative back to whoever asked for it.
///
/// The transport hands a pushed message to a closure on its own queue, with no
/// reference to the actor that opened the session and no way to await anything. Holding
/// the consumer's closures behind a lock here is what lets that queue reach the
/// consumer, and keeping the decode here rather than in the transport handler means the
/// behaviour can be tested without a live connection.
///
/// Nothing here hops to the main thread. The consumer decides where a snapshot is
/// applied.
public final class AgentPushDelivery: Sendable {
  private struct Handlers {
    var onSnapshot: (@Sendable (TunnelDaemonStatusSnapshot) -> Void)?
    var onDisconnect: (@Sendable () -> Void)?
  }

  private let handlers = Mutex(Handlers())

  public init() {
    // Nothing to set up: the handlers arrive when a consumer subscribes.
  }

  @preconcurrency
  public func setHandlers(
    onSnapshot: @escaping @Sendable (TunnelDaemonStatusSnapshot) -> Void,
    onDisconnect: @escaping @Sendable () -> Void
  ) {
    handlers.withLock { current in
      current.onSnapshot = onSnapshot
      current.onDisconnect = onDisconnect
    }
  }

  public func clearHandlers() {
    handlers.withLock { $0 = Handlers() }
  }

  /// Decodes one pushed message and hands the snapshot over.
  ///
  /// Anything that is not a response carrying a status is dropped rather than reported.
  /// A message the transport delivered with nothing in it, or one this version does not
  /// understand, says nothing about the tunnel, and reporting it as an error would
  /// replace a good reading on screen with a false one.
  ///
  /// The closure is copied out before it is called, so a consumer that subscribes again
  /// from inside it does not deadlock on the lock held here.
  public func deliver(payload: Data?) {
    guard let payload else {
      return
    }
    let decoded: AgentControlResponse
    do {
      decoded = try JSONDecoder().decode(AgentControlResponse.self, from: payload)
    } catch {
      // Dropping is the recovery. This is not the tunnel reporting a problem; it is a
      // message this version cannot read, and turning it into an error on screen would
      // be a claim about the tunnel that nothing supports. The message itself stays out
      // of the log, because it can carry configuration text.
      logger.error(
        """
        agent push ignored reason=unreadable-message \
        kind=\(String(describing: type(of: error)), privacy: .public) recovery=drop
        """
      )
      return
    }
    guard let status = decoded.status else {
      return
    }
    let onSnapshot = handlers.withLock { $0.onSnapshot }
    onSnapshot?(status)
  }

  /// Reports the session ending, once.
  ///
  /// Cancelling locally and hearing that the peer is gone are two notices of the same
  /// disconnect, so the handlers are cleared as the first fires and the second finds
  /// nothing to call.
  public func reportDisconnected() {
    let onDisconnect = handlers.withLock { current -> (@Sendable () -> Void)? in
      let handler = current.onDisconnect
      current = Handlers()
      return handler
    }
    onDisconnect?()
  }
}

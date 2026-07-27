//
//  SubscriberRegistry.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Synchronization

// MARK: - SubscriberRegistry

/// Holds the way to reach each client that asked to be told about changes.
///
/// The agent answers requests on connections it does not otherwise keep track
/// of, so without this it can only ever speak when spoken to. That forces every
/// client to ask repeatedly, which is why the app polls once a second and why a
/// change is invisible until the next tick.
///
/// Each entry is a closure rather than a connection handle, so the registry
/// stays free of the transport and can be tested without one.
public final class SubscriberRegistry: Sendable {
  private let subscribers = Mutex<[UUID: @Sendable (Data) -> Void]>([:])

  public init() {
    // No state to seed; every subscriber arrives through `add`.
  }

  /// How many clients are currently listening.
  public var count: Int {
    subscribers.withLock { $0.count }
  }

  /// Whether nobody is listening, so a broadcast would reach no one.
  public var isEmpty: Bool {
    subscribers.withLock { $0.isEmpty }
  }

  /// Registers a way to reach one client, returning the token that removes it.
  @preconcurrency
  public func add(_ send: @escaping @Sendable (Data) -> Void) -> UUID {
    let token = UUID()
    subscribers.withLock { $0[token] = send }
    return token
  }

  /// Stops reaching one client. Removing a token that is already gone is normal,
  /// because a dropped connection and an explicit unsubscribe can both arrive.
  public func remove(_ token: UUID) {
    subscribers.withLock { $0[token] = nil }
  }

  /// Sends one payload to every listening client.
  ///
  /// The sends run outside the lock so a slow or blocked client cannot hold up
  /// the state change that triggered the broadcast.
  public func broadcast(_ payload: Data) {
    let targets = subscribers.withLock { Array($0.values) }
    for send in targets {
      send(payload)
    }
  }
}

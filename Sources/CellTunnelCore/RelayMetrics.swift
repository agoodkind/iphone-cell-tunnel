//
//  RelayMetrics.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-28.
//  Copyright © 2026, all rights reserved.
//

import Synchronization

/// Lock-free relay counters shared by the macOS provider and the iPhone relay.
///
/// Each counter is its own `Atomic<UInt64>` stored property because `Atomic` is
/// non-copyable and cannot live inside an array, tuple, or struct. The increment
/// helpers run on the per-datagram hot path and use relaxed ordering, since the
/// counts have no ordering dependency on other memory. `snapshot()` reads every
/// field into a copyable `TunnelCounters` for logging and the status wire format.
public final class RelayMetrics: Sendable {
  private let datagramsFromMac = Atomic<UInt64>(0)
  private let datagramsToMac = Atomic<UInt64>(0)
  private let datagramsToServer = Atomic<UInt64>(0)
  private let datagramsFromServer = Atomic<UInt64>(0)
  private let droppedDatagrams = Atomic<UInt64>(0)
  private let bytesIn = Atomic<UInt64>(0)
  private let bytesOut = Atomic<UInt64>(0)

  public init() {
    // All counters start at zero.
  }

  public func addDatagramsFromMac(_ count: UInt64 = 1) {
    datagramsFromMac.wrappingAdd(count, ordering: .relaxed)
  }

  public func addDatagramsToMac(_ count: UInt64 = 1) {
    datagramsToMac.wrappingAdd(count, ordering: .relaxed)
  }

  public func addDatagramsToServer(_ count: UInt64 = 1) {
    datagramsToServer.wrappingAdd(count, ordering: .relaxed)
  }

  public func addDatagramsFromServer(_ count: UInt64 = 1) {
    datagramsFromServer.wrappingAdd(count, ordering: .relaxed)
  }

  public func addDropped(_ count: UInt64 = 1) {
    droppedDatagrams.wrappingAdd(count, ordering: .relaxed)
  }

  public func addBytesIn(_ count: UInt64) {
    bytesIn.wrappingAdd(count, ordering: .relaxed)
  }

  public func addBytesOut(_ count: UInt64) {
    bytesOut.wrappingAdd(count, ordering: .relaxed)
  }

  public func snapshot() -> TunnelCounters {
    TunnelCounters(
      wireGuardDatagramsFromMac: datagramsFromMac.load(ordering: .relaxed),
      wireGuardDatagramsToMac: datagramsToMac.load(ordering: .relaxed),
      wireGuardDatagramsToServer: datagramsToServer.load(ordering: .relaxed),
      wireGuardDatagramsFromServer: datagramsFromServer.load(ordering: .relaxed),
      droppedWireGuardDatagrams: droppedDatagrams.load(ordering: .relaxed),
      relayBytesIn: bytesIn.load(ordering: .relaxed),
      relayBytesOut: bytesOut.load(ordering: .relaxed)
    )
  }
}

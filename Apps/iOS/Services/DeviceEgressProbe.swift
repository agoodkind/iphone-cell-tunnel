//
//  DeviceEgressProbe.swift
//  CellTunnelPhone
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-06-05.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Synchronization

// MARK: - Constants

private let logger = CellTunnelLog.logger(category: .app)
private let publicAddressRefreshIntervalSeconds = 60

// MARK: - DeviceEgressProbe

/// Watches the app's own default egress and measures the app's public address, so the
/// `Device` rows have a value before the relay runs and whenever the relay does not
/// carry the device's own traffic. It pairs `EgressPathMonitor` with the unpinned
/// default path and `PublicAddressProbe`, and reports both through `onUpdate`. It runs
/// on both the Catalyst app and the iPhone app for the app's lifetime.
///
/// `@unchecked Sendable`: the latest reading is held behind a `Mutex`, `onUpdate` is
/// set once before `start()`, and the monitor and timer handlers run off the main
/// thread and hop as the consumer requires.
final class DeviceEgressProbe: @unchecked Sendable {
  private struct State {
    var cellularPath = CellularPathSnapshot()
    var publicAddresses = AddressPair.empty
  }

  private let monitor = EgressPathMonitor(requiredInterfaceType: nil)
  private let probe = PublicAddressProbe()
  private let state = Mutex(State())
  private var refreshTimer: DispatchSourceTimer?

  /// Fired with the app's latest egress path and public address. Set before `start()`.
  var onUpdate: (@Sendable (CellularPathSnapshot, AddressPair) -> Void)?

  // MARK: - Lifecycle

  /// Starts the egress monitor and the periodic public-address backstop.
  func start() {
    monitor.onChange = { [weak self] egress in
      self?.handleEgress(egress)
    }
    monitor.start()
    startRefreshTimer()
    logger.notice("device egress probe started")
  }

  // MARK: - Egress

  // Stores the new egress reading, reports it with the last known public address,
  // then re-probes the public address since the path just changed.
  private func handleEgress(_ egress: EgressPath) {
    let snapshot = CellularPathSnapshot(egress: egress)
    let current = state.withLock { existing -> State in
      existing.cellularPath = snapshot
      return existing
    }
    onUpdate?(current.cellularPath, current.publicAddresses)
    refreshPublicAddress()
  }

  // MARK: - Public address

  // Measures the app's public address and reports the new pair with the current
  // egress path. Driven by an egress change and the periodic backstop.
  private func refreshPublicAddress() {
    let addressProbe = probe
    Task { [weak self] in
      let pair = await addressProbe.probe()
      guard let self else {
        return
      }
      let current = state.withLock { existing -> State in
        existing.publicAddresses = pair
        return existing
      }
      onUpdate?(current.cellularPath, current.publicAddresses)
    }
  }

  private func startRefreshTimer() {
    refreshTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(
      deadline: .now() + .seconds(publicAddressRefreshIntervalSeconds),
      repeating: .seconds(publicAddressRefreshIntervalSeconds)
    )
    timer.setEventHandler { @Sendable [weak self] in
      self?.refreshPublicAddress()
    }
    timer.resume()
    refreshTimer = timer
    logger.notice(
      """
      device egress probe refresh timer started \
      intervalSeconds=\(publicAddressRefreshIntervalSeconds, privacy: .public)
      """
    )
  }
}

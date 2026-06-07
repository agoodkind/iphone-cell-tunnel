//
//  CellularPathObserver.swift
//  CellTunnelRelay
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-29.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network
import Synchronization

private let logger = CellTunnelLog.logger(category: .relay)

/// Reports the iPhone egress path for status. It runs the shared `EgressPathMonitor`
/// and maps each reading to the `CellularPathSnapshot` the provider reads for the
/// status screen, and forwards a change signal the runtime uses to re-probe the
/// public address. The provider owns one instance, starts it in `startTunnel`, and
/// cancels it in `stopTunnel`.
final class CellularPathObserver: @unchecked Sendable {
  private let monitor: EgressPathMonitor
  private let latestSnapshot = Mutex(CellularPathSnapshot())
  private let pathChangeHandler = Mutex<(@Sendable () -> Void)?>(nil)

  /// Watches a specific interface type, or the general path when
  /// `requiredInterfaceType` is nil. The device pins the cellular radio; the
  /// in-process simulator host, which has no cellular radio, watches the general
  /// path so a satisfied host network drives the connected status the same way a
  /// live cellular path does on device.
  init(requiredInterfaceType: NWInterface.InterfaceType?) {
    monitor = EgressPathMonitor(requiredInterfaceType: requiredInterfaceType)
  }

  var snapshot: CellularPathSnapshot {
    latestSnapshot.withLock { $0 }
  }

  /// Registers the handler the runtime calls on each egress path change, so it can
  /// re-probe and re-send the public address. Set before `start()`.
  func setPathChangeHandler(_ handler: @escaping @Sendable () -> Void) {
    pathChangeHandler.withLock { $0 = handler }
  }

  func start() {
    monitor.onChange = { [weak self] path in
      guard let self else {
        return
      }
      latestSnapshot.withLock { $0 = CellularPathSnapshot(egress: path) }
      pathChangeHandler.withLock { $0 }?()
    }
    monitor.start()
    logger.info("cellular path observer started")
  }

  func stop() {
    monitor.stop()
    latestSnapshot.withLock { $0 = CellularPathSnapshot() }
    logger.info("cellular path observer stopped")
  }
}

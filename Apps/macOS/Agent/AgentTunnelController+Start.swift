//
//  AgentTunnelController+Start.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-29.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
@preconcurrency import NetworkExtension

private let logger = CellTunnelLog.logger(category: .daemon)
private let sessionConnectTimeoutSeconds = 30
/// How long to wait for a session to finish going down before starting it again. A stop
/// completes in about a second, so this is a bound rather than an expected wait.
private let sessionDisconnectTimeoutSeconds = 15

extension AgentTunnelController {
  func loadAllManagers() async throws -> [NETunnelProviderManager] {
    try await NETunnelProviderManager.loadAllFromPreferences()
  }

  func resumeVoidContinuation(
    _ body: (@escaping @Sendable (Error?) -> Void) -> Void
  ) async throws {
    let _: Void = try await withCheckedThrowingContinuation { continuation in
      body { error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        continuation.resume()
      }
    }
  }

  // Resolve the relay service name the provider should target, from the agent's
  // warm browser: a still visible persisted selection, else the first device.
  // Handing the provider a concrete name lets the extension skip the slow first
  // service cold browse that makes the first start fail.
  func resolvedRelayServiceName() -> String? {
    let warmDevices = relayBrowser.snapshot()
    let persisted = RelaySelectionStore.selectedRelayServiceName()
    if let persisted, warmDevices.contains(where: { $0.serviceName == persisted }) {
      return persisted
    }
    return warmDevices.first?.serviceName
  }

  // start should report the real outcome, not a snapshot taken before the
  // provider has discovered the relay and connected. Wait for the connection to
  // reach connected, or give up after the timeout so a genuine discovery failure
  // still returns. Bounded so the CLI cannot hang.
  func waitForSessionConnected(on manager: NETunnelProviderManager) async {
    await waitForSession(
      on: manager,
      describing: "connected",
      timeoutSeconds: sessionConnectTimeoutSeconds
    ) { status in
      status == .connected
    }
  }

  /// Waits for the session to finish going down, so a restart does not ask it to start
  /// while it is still disconnecting, which the system ignores.
  ///
  /// An invalid connection counts as down: the profile went away, so nothing is left to
  /// wait for.
  func waitForSessionDisconnected(on manager: NETunnelProviderManager) async {
    await waitForSession(
      on: manager,
      describing: "disconnected",
      timeoutSeconds: sessionDisconnectTimeoutSeconds
    ) { status in
      status == .disconnected || status == .invalid
    }
  }

  private func waitForSession(
    on manager: NETunnelProviderManager,
    describing target: String,
    timeoutSeconds: Int,
    until isReached: @escaping @Sendable (NEVPNStatus) -> Bool
  ) async {
    let connection = manager.connection
    if isReached(connection.status) {
      return
    }
    await SessionStatusWaiter(describing: target, isReached: isReached).wait(
      on: connection,
      timeoutSeconds: timeoutSeconds
    )
  }

  func statusDescription(_ status: NEVPNStatus) -> String {
    switch status {
    case .invalid:
      return "invalid"
    case .disconnected:
      return "disconnected"
    case .connecting:
      return "connecting"
    case .connected:
      return "connected"
    case .reasserting:
      return "reasserting"
    case .disconnecting:
      return "disconnecting"
    @unknown default:
      return "unknown"
    }
  }

  func failure(from error: Error) -> AgentControlResponse {
    if let controllerError = error as? AgentTunnelControllerError {
      return failure(errorCode: controllerError.errorCode, message: controllerError.message)
    }
    // A refused profile save arrives here already carrying its what-happened-and-what-to-do
    // message, attached where the save actually ran. Classifying by error code here
    // instead would also catch the same code from a failed preferences read, and tell a
    // person to answer a permission prompt that never appeared.
    return failure(errorCode: .internal, message: error.localizedDescription)
  }

  func failure(
    errorCode: TunnelControlErrorCode,
    message: String
  ) -> AgentControlResponse {
    AgentControlResponse(failure: AgentControlFailure(errorCode: errorCode, message: message))
  }
}

// Resolves once the VPN connection reaches the status the caller is waiting for, or
// after a bounded timeout, using the status notification and a scheduled deadline
// rather than polling. The lock makes the single continuation resume exactly once
// across the observer and the timeout.
// MARK: - SessionStatusWaiter

private final class SessionStatusWaiter: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  private var observer: NSObjectProtocol?
  private var timeoutItem: DispatchWorkItem?
  private let target: String
  private let isReached: @Sendable (NEVPNStatus) -> Bool

  init(describing target: String, isReached: @escaping @Sendable (NEVPNStatus) -> Bool) {
    self.target = target
    self.isReached = isReached
  }

  func wait(on connection: NEVPNConnection, timeoutSeconds: Int) async {
    logger.notice(
      "agent waiting for tunnel session to reach \(self.target, privacy: .public)")
    await withCheckedContinuation { pending in
      lock.lock()
      continuation = pending
      lock.unlock()

      observer = NotificationCenter.default.addObserver(
        forName: .NEVPNStatusDidChange,
        object: connection,
        queue: nil
      ) { [weak self] _ in
        guard let self, isReached(connection.status) else {
          return
        }
        finish(reason: target)
      }
      let item = DispatchWorkItem { [weak self] in
        self?.finish(reason: "timeout")
      }
      timeoutItem = item
      DispatchQueue.global(qos: .userInitiated).asyncAfter(
        deadline: .now() + .seconds(timeoutSeconds),
        execute: item
      )
      if isReached(connection.status) {
        finish(reason: target)
      }
    }
  }

  private func finish(reason: String) {
    lock.lock()
    let pending = continuation
    continuation = nil
    let activeObserver = observer
    observer = nil
    let timer = timeoutItem
    timeoutItem = nil
    lock.unlock()

    if let activeObserver {
      NotificationCenter.default.removeObserver(activeObserver)
    }
    timer?.cancel()
    guard let pending else {
      return
    }
    logger.notice(
      "agent tunnel session connect wait resolved reason=\(reason, privacy: .public)"
    )
    pending.resume()
  }
}

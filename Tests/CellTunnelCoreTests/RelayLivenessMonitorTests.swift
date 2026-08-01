//
//  RelayLivenessMonitorTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import Network
import NetworkExtension
import Testing

@testable import CellTunnelTunnelRuntime

@MainActor
@Suite("Relay liveness monitor")
struct RelayLivenessMonitorTests {
  /// The whole point of the change, driven end to end over a real loopback
  /// socket: while the agent answers, a working tunnel keeps its routes, and when
  /// the agent's listener goes away the gate withdraws the captured routes and the
  /// tunnel resolver so traffic falls back to the physical interface.
  @Test("routes stay installed while the agent answers and withdraw when it stops")
  func agentGoingAwayWithdrawsRoutes() async throws {
    let agent = EchoingAgentListener(mode: .heartbeat)
    let port = try await agent.start()
    let gate = RouteGate()
    let settings = Self.makeSettings()
    _ = gate.record(settings)
    _ = gate.setProgramRoutes(
      ipv4: [NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0")],
      ipv6: []
    )
    _ = gate.setProgramDNS(servers: ["10.0.0.1"], searchDomains: [])
    let installedSettings = gate.setInstalled(true)
    // Assert on what the gate hands to the system, which is the contract, rather than on
    // the object the tunnel supplied, which the gate leaves as its own record.
    #expect(installedSettings?.ipv4Settings?.includedRoutes?.isEmpty == false)
    #expect(installedSettings?.dnsSettings != nil)

    let transport = RelayTransport(metrics: RelayMetrics())
    try transport.connect(to: .hostPort(host: "127.0.0.1", port: port))
    let monitor = RelayLivenessMonitor(
      transport: transport,
      missedRepliesBeforeGone: 2,
      intervalMilliseconds: 100
    )
    let withdrawnSettings = WithdrawnSettingsBox()
    monitor.onAgentGone = { [gate] in
      withdrawnSettings.value = gate.setInstalled(false)
    }
    monitor.start()

    // Several ticks with the agent answering must leave a working tunnel alone.
    try await Task.sleep(for: .milliseconds(500))
    let stayedInstalled = gate.isInstalled

    agent.stop()
    let withdrew = try await waitUntil(timeoutSeconds: 5) {
      !gate.isInstalled
    }
    monitor.stop()
    transport.disconnect()

    #expect(stayedInstalled)
    #expect(withdrew)
    #expect(withdrawnSettings.value?.ipv4Settings?.includedRoutes?.isEmpty == true)
    #expect(withdrawnSettings.value?.dnsSettings == nil)
  }

  private static func makeSettings() -> NEPacketTunnelNetworkSettings {
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    settings.ipv4Settings = NEIPv4Settings(
      addresses: ["10.0.0.2"],
      subnetMasks: ["255.255.255.0"]
    )
    return settings
  }

  /// Polls until the condition holds, so a real timer and a real socket decide the
  /// timing rather than a fixed sleep.
  private func waitUntil(timeoutSeconds: Double, _ condition: () -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
      if condition() {
        return true
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    return condition()
  }
}

// MARK: - WithdrawnSettingsBox

/// Carries the settings the withdrawal produced out of the monitor's callback, which runs
/// on the monitor's own queue rather than the test's.
private final class WithdrawnSettingsBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: NEPacketTunnelNetworkSettings?

  var value: NEPacketTunnelNetworkSettings? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return stored
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      stored = newValue
    }
  }
}

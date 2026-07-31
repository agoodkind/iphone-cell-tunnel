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
    _ = gate.setInstalled(true)
    #expect(settings.ipv4Settings?.includedRoutes?.isEmpty == false)
    #expect(settings.dnsSettings != nil)

    let transport = RelayTransport(metrics: RelayMetrics())
    try transport.connect(to: .hostPort(host: "127.0.0.1", port: port))
    let monitor = RelayLivenessMonitor(
      transport: transport,
      missedRepliesBeforeGone: 2,
      intervalMilliseconds: 100
    )
    monitor.onAgentGone = { [gate] in
      _ = gate.setInstalled(false)
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
    #expect(settings.ipv4Settings?.includedRoutes?.isEmpty == true)
    #expect(settings.dnsSettings == nil)
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

//
//  TunnelControlSmokeTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-22.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Testing

private let logger = CellTunnelLog.logger(category: .daemon)

struct TunnelControlSmokeTests {
  @Test func cliParseSmokeRequiresConfigAndPeer() {
    #expect(throws: (any Error).self) {
      try TunnelControlCLIAction.parse(arguments: ["smoke", "--peer", "1"])
    }
    #expect(throws: (any Error).self) {
      try TunnelControlCLIAction.parse(arguments: ["smoke", "--config", "/tmp/wg.conf"])
    }
  }

  @Test func cliParseSmokeRejectsUnknownOption() {
    #expect(throws: (any Error).self) {
      try TunnelControlCLIAction.parse(
        arguments: ["smoke", "--config", "/tmp/wg.conf", "--peer", "1", "--bogus", "x"])
    }
  }

  @Test func cliParseSmokeStoresFlags() throws {
    let action = try TunnelControlCLIAction.parse(
      arguments: [
        "smoke", "--config", "/tmp/wg.conf", "--peer", "1", "--relay", "[fd00::44]:51820",
      ])

    guard case .smoke(let settings) = action else {
      Issue.record("unexpected action: \(action)")
      return
    }
    #expect(settings.wireGuardConfigPath == "/tmp/wg.conf")
    #expect(settings.peerReference == "1")
    #expect(settings.relayEndpoint?.socketAddress == "[fd00::44]:51820")
  }

  @Test func cliExecutorSmokeRejectsDefaultRouteAllowedIPs() async throws {
    let client = SmokeTunnelControlClient()
    let probes = RecordingSmokeProbeRunner()
    let directory = FileManager.default.temporaryDirectory
    let url = directory.appendingPathComponent("smoke-default-\(UUID().uuidString).conf")
    let fixtureInterfaceKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    let fixturePeerKey = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
    let privateKeyLine = "PrivateKey = \(fixtureInterfaceKey)"  // gitleaks:allow
    let publicKeyLine = "PublicKey = \(fixturePeerKey)"  // gitleaks:allow
    let config = """
      [Interface]
      \(privateKeyLine)
      Address = 10.0.0.2/32

      [Peer]
      \(publicKeyLine)
      Endpoint = relay.example.com:51820
      AllowedIPs = 0.0.0.0/0, ::/0
      """
    try Data(config.utf8).write(to: url, options: .atomic)
    defer {
      do {
        try FileManager.default.removeItem(at: url)
      } catch {
        logger.error(
          """
          temp smoke config cleanup failed \
          details=\(String(describing: error), privacy: .public) recovery=leave-temp-file
          """
        )
        Issue.record("temp smoke config cleanup failed: \(error)")
      }
    }
    let settings = SmokeSettings(wireGuardConfigPath: url.path, peerReference: "1")

    await #expect(throws: (any Error).self) {
      try await runSmokeCLI(.smoke(settings), on: client, probeRunner: probes)
    }
    #expect(probes.commands.isEmpty)
    #expect(client.events.isEmpty)
  }

  @Test func cliExecutorSmokeRunsExpectedRPCsAndProbes() async throws {
    let client = SmokeTunnelControlClient()
    let probes = RecordingSmokeProbeRunner()
    let directory = FileManager.default.temporaryDirectory
    let url = directory.appendingPathComponent("smoke-\(UUID().uuidString).conf")
    // Key assignments sit on allowlisted lines so the secret scanner does not
    // flag these non-secret parse fixtures (same pattern as WireGuardConfigParserTests).
    // Avoid a `*PrivateKey =` Swift binding name; that trips the generic secret rule.
    let fixtureInterfaceKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    let fixturePeerKey = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
    let privateKeyLine = "PrivateKey = \(fixtureInterfaceKey)"  // gitleaks:allow
    let publicKeyLine = "PublicKey = \(fixturePeerKey)"  // gitleaks:allow
    let config = """
      [Interface]
      \(privateKeyLine)
      Address = 10.0.0.2/32

      [Peer]
      \(publicKeyLine)
      Endpoint = relay.example.com:51820
      AllowedIPs = 208.67.222.222/32, 2620:119:35::35/128
      """
    try Data(config.utf8).write(to: url, options: .atomic)
    defer {
      do {
        try FileManager.default.removeItem(at: url)
      } catch {
        logger.error(
          """
          temp smoke config cleanup failed \
          details=\(String(describing: error), privacy: .public) recovery=leave-temp-file
          """
        )
        Issue.record("temp smoke config cleanup failed: \(error)")
      }
    }
    let settings = SmokeSettings(wireGuardConfigPath: url.path, peerReference: "1")

    let output = try await runSmokeCLI(.smoke(settings), on: client, probeRunner: probes)

    #expect(client.events.contains("startPairing"))
    #expect(client.events.contains("stopTunnel"))
    #expect(client.events.contains("startTunnel"))
    #expect(client.events.filter { $0 == "status" }.count >= 5)
    #expect(probes.commands.count == 4)
    #expect(probes.commands[0] == ["ping", "-c", "5", "208.67.222.222"])
    #expect(probes.commands[1] == ["ping6", "-c", "5", "-s", "16", "2620:119:35::35"])
    #expect(probes.commands[2] == ["curl", "-v", "https://208.67.222.222/"])
    #expect(probes.commands[3] == ["curl", "-v", "-g", "https://[2620:119:35::35]/"])
    #expect(output.contains("== status =="))
    #expect(output.contains("== pairing =="))
    #expect(output.contains("== peers =="))
    #expect(output.contains("== select =="))
    #expect(output.contains("== stop =="))
    #expect(output.contains("== start =="))
    #expect(output.contains("== routes =="))
    #expect(output.contains("== probes =="))
    #expect(output.contains("outbound="))
    #expect(output.contains("inbound="))
  }
}

//
//  TunnelControlModelsTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-24.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Testing

private let logger = CellTunnelLog.logger(category: .daemon)
private let relayPort = 51_820
private let discoverySelectionPort = 5_354

struct TunnelControlModelsTests {
  @Test func startSettingsUsesDaemonSelectedRelayByDefault() {
    let settings = TunnelStartSettings(wireGuardConfigPath: "/tmp/wg.conf")

    #expect(settings.isReadyToStart)
    #expect(settings.usesDaemonSelectedRelay)
    #expect(!settings.hasLocalRelayEndpoint)
  }

  @Test func relayEndpointParsesBracketedIPv6() throws {
    let endpoint = try TunnelRelayEndpoint.parse(argument: "[fd00::44]:51820")

    #expect(endpoint.host == "fd00::44")
    #expect(endpoint.port == relayPort)
    #expect(endpoint.addressFamily == .ipv6)
    #expect(endpoint.socketAddress == "[fd00::44]:51820")
  }

  @Test func cliParseStartWithExplicitRelay() throws {
    let action = try TunnelControlCLIAction.parse(
      arguments: ["start", "--config", "/tmp/wg.conf", "--relay", "[fd00::44]:51820"]
    )

    guard case .start(let settings) = action else {
      Issue.record("unexpected action: \(action)")
      return
    }
    #expect(settings.wireGuardConfigPath == "/tmp/wg.conf")
    #expect(settings.relayEndpoint?.socketAddress == "[fd00::44]:51820")
  }

  @Test func cliParsePeers() throws {
    let action = try TunnelControlCLIAction.parse(arguments: ["peers"])

    #expect(action == .peers)
  }

  @Test func cliParseSelectRequiresReference() {
    #expect(throws: (any Error).self) {
      try TunnelControlCLIAction.parse(arguments: ["select"])
    }
  }

  @Test func cliParseSelectRejectsExtraArguments() {
    #expect(throws: (any Error).self) {
      try TunnelControlCLIAction.parse(arguments: ["select", "relay-1", "extra"])
    }
  }

  @Test func cliParseSelectTrimsAndStoresReference() throws {
    let action = try TunnelControlCLIAction.parse(arguments: ["select", "  relay-1  "])

    #expect(action == .select(reference: "relay-1"))
  }

  @Test func cliExecutorPeersListsNumberedServices() async throws {
    let client = FakeTunnelControlClient()

    let output = try await runCLI(.peers, on: client)

    #expect(client.events == ["listRelayServices"])
    #expect(output == "1) CellTunnelPhone  relay-1")
  }

  @Test func cliExecutorPeersReportsEmptyListing() async throws {
    let client = FakeTunnelControlClient()
    client.listedDiscoverySnapshotOverride = TunnelDiscoverySnapshot(
      phase: .browsing,
      services: []
    )

    let output = try await runCLI(.peers, on: client)

    #expect(output == "no peers found")
  }

  @Test func cliExecutorSelectByServiceIDCallsSelectRelayService() async throws {
    let client = FakeTunnelControlClient()

    let output = try await runCLI(.select(reference: "relay-1"), on: client)

    #expect(client.events == ["selectRelayService"])
    #expect(output == client.selectedDiscoverySnapshot.renderedOutput)
  }

  @Test func cliExecutorSelectByIndexResolvesServiceID() async throws {
    let client = FakeTunnelControlClient()

    let output = try await runCLI(.select(reference: "1"), on: client)

    #expect(client.events == ["listRelayServices", "selectRelayService"])
    #expect(output == client.selectedDiscoverySnapshot.renderedOutput)
  }

  @Test func cliExecutorSelectByOutOfRangeIndexThrows() async {
    let client = FakeTunnelControlClient()

    let thrownError = await captureError {
      _ = try await runCLI(.select(reference: "9"), on: client)
    }

    guard let daemonError = thrownError as? TunnelDaemonError, case .usage = daemonError else {
      Issue.record("expected usage error, got \(String(describing: thrownError))")
      return
    }
    #expect(client.events == ["listRelayServices"])
  }

  @Test func statusSnapshotRendersDiscoverySelection() {
    let endpoint = TunnelRelayEndpoint(
      host: "fd00::1",
      port: discoverySelectionPort,
      addressFamily: .ipv6
    )
    let discovery = TunnelDiscoverySnapshot(
      phase: .ready,
      services: [],
      selectedServiceID: "relay-1",
      selectedEndpoint: endpoint,
      lastError: nil
    )
    let snapshot = TunnelDaemonStatusSnapshot(
      running: true,
      routeState: .installed,
      peerState: .wireGuardConfigured,
      ipv4Address: "198.18.0.2",
      ipv6Address: "fd7a:ce11:7a11::2",
      lastError: nil,
      discovery: discovery,
      activeRelayEndpoint: endpoint
    )

    #expect(snapshot.running)
    #expect(snapshot.routeState == .installed)
    #expect(snapshot.peerState == .wireGuardConfigured)
    #expect(snapshot.discovery.selectedServiceID == "relay-1")
    #expect(snapshot.activeRelayEndpoint?.socketAddress == "[fd00::1]:5354")
  }
}

// Single boundary the suite uses to drive the async CLI executor; logs the
// crossing so this one call into the runtime carries structured context.
private func runCLI(
  _ action: TunnelControlCLIAction,
  on client: FakeTunnelControlClient
) async throws -> String {
  logger.debug("test driving cli executor action")
  let executor = TunnelControlCLIExecutor(client: client)
  return try await executor.run(action: action)
}

// Runs a throwing operation and returns the thrown error so the caller can
// assert on it without a bare catch the swiftcheck-extra audit treats as silent.
private func captureError(
  during operation: () async throws -> Void
) async -> Error? {
  do {
    try await operation()
    return nil
  } catch {
    return error
  }
}

private func makeRelayService(
  serviceID: String,
  serviceName: String,
  host: String,
  endpointHost: String,
  endpointPort: Int,
  isSelected: Bool = false
) -> TunnelRelayService {
  let endpoint = TunnelRelayEndpoint(
    host: endpointHost,
    port: endpointPort,
    addressFamily: .ipv6
  )
  return TunnelRelayService(
    id: serviceID,
    serviceName: serviceName,
    serviceType: "_cellrelay._udp",
    domain: "local.",
    interfaceIndex: 0,
    hostName: host,
    endpoints: [endpoint],
    preferredEndpoint: endpoint,
    isSelected: isSelected
  )
}

// MARK: - FakeTunnelControlClient

private final class FakeTunnelControlClient: TunnelControlClientProtocol, @unchecked Sendable {
  var events: [String] = []
  let startDiscoverySnapshot = TunnelDiscoverySnapshot(
    phase: .browsing,
    services: [],
    selectedServiceID: nil,
    selectedEndpoint: nil,
    lastError: nil
  )
  var listedDiscoverySnapshotOverride: TunnelDiscoverySnapshot?
  let listedDiscoverySnapshot = TunnelDiscoverySnapshot(
    phase: .ready,
    services: [
      makeRelayService(
        serviceID: "relay-1",
        serviceName: "CellTunnelPhone",
        host: "iphone.local",
        endpointHost: "fd00::44",
        endpointPort: relayPort
      )
    ],
    selectedServiceID: nil,
    selectedEndpoint: nil,
    lastError: nil
  )
  let selectedDiscoverySnapshot = TunnelDiscoverySnapshot(
    phase: .ready,
    services: [
      makeRelayService(
        serviceID: "relay-1",
        serviceName: "CellTunnelPhone",
        host: "iphone.local",
        endpointHost: "fd00::44",
        endpointPort: relayPort,
        isSelected: true
      )
    ],
    selectedServiceID: "relay-1",
    selectedEndpoint: TunnelRelayEndpoint(
      host: "fd00::44",
      port: relayPort,
      addressFamily: .ipv6
    ),
    lastError: nil
  )

  func status() async -> TunnelDaemonStatusSnapshot {
    await Task.yield()
    events.append("status")
    return TunnelDaemonStatusSnapshot()
  }

  func check() async -> TunnelEnvironmentReport {
    await Task.yield()
    events.append("check")
    return TunnelEnvironmentReport()
  }

  func startTunnel(settings: TunnelStartSettings) async -> TunnelDaemonStatusSnapshot {
    await Task.yield()
    events.append("startTunnel")
    _ = settings
    return TunnelDaemonStatusSnapshot()
  }

  func stopTunnel() async -> TunnelDaemonStatusSnapshot {
    await Task.yield()
    events.append("stopTunnel")
    return TunnelDaemonStatusSnapshot()
  }

  func reset() async -> TunnelDaemonStatusSnapshot {
    await Task.yield()
    events.append("reset")
    return TunnelDaemonStatusSnapshot()
  }

  func startRelayDiscovery() async -> TunnelDiscoverySnapshot {
    await Task.yield()
    events.append("startRelayDiscovery")
    return startDiscoverySnapshot
  }

  func stopRelayDiscovery() async -> TunnelDiscoverySnapshot {
    await Task.yield()
    events.append("stopRelayDiscovery")
    return startDiscoverySnapshot
  }

  func listRelayServices() async -> TunnelDiscoverySnapshot {
    await Task.yield()
    events.append("listRelayServices")
    return listedDiscoverySnapshotOverride ?? listedDiscoverySnapshot
  }

  func selectRelayService(serviceID: String) async -> TunnelDiscoverySnapshot {
    await Task.yield()
    events.append("selectRelayService")
    #expect(serviceID == "relay-1")
    return selectedDiscoverySnapshot
  }
}

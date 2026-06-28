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
private let fixedConfigEpoch: TimeInterval = 1_717_200_000
private let configIDOne = UUID()
private let configIDTwo = UUID()

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

  @Test func validateConfigRequestRoundTripsThroughEnvelope() throws {
    let text = """
      [Interface]
      Address = 198.18.0.2/32

      [Peer]
      Endpoint = relay.example:51820
      """
    let envelope = AgentControlEnvelope(request: .validateConfig(text: text))
    let encoded = try JSONEncoder().encode(envelope)

    let decoded = try JSONDecoder().decode(AgentControlEnvelope.self, from: encoded)

    #expect(decoded.version == agentControlWireVersion)
    guard case .validateConfig(let decodedText) = decoded.request else {
      Issue.record("unexpected request: \(decoded.request)")
      return
    }
    #expect(decodedText == text)
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

  @Test func cliExecutorPeersListsRoster() async throws {
    let client = FakeTunnelControlClient()

    let output = try await runCLI(.peers, on: client)

    #expect(client.events == ["status"])
    #expect(output == "1) Alex iPhone  13452847362910")
  }

  @Test func cliExecutorPeersReportsEmptyRoster() async throws {
    let client = FakeTunnelControlClient()
    client.connectedPeersOverride = []

    let output = try await runCLI(.peers, on: client)

    #expect(output == "no peers found")
  }

  @Test func cliExecutorSelectByIndexSelectsEgressPeer() async throws {
    let client = FakeTunnelControlClient()

    let output = try await runCLI(.select(reference: "1"), on: client)

    #expect(client.events == ["status", "selectEgressPeer"])
    #expect(output == client.selectedStatusSnapshot.renderedOutput)
  }

  @Test func cliExecutorSelectRejectsNonIndexReference() async {
    let client = FakeTunnelControlClient()

    let thrownError = await captureError {
      _ = try await runCLI(.select(reference: "abc"), on: client)
    }

    guard let daemonError = thrownError as? TunnelDaemonError, case .usage = daemonError else {
      Issue.record("expected usage error, got \(String(describing: thrownError))")
      return
    }
    #expect(client.events.isEmpty)
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
    #expect(client.events == ["status"])
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

  @Test func configSummaryRoundTripsThroughCoding() throws {
    let date = Date(timeIntervalSince1970: fixedConfigEpoch)
    let summary = TunnelConfigSummary(id: configIDOne, name: "Home", createdAt: date)

    let encoded = try JSONEncoder().encode(summary)
    let decoded = try JSONDecoder().decode(TunnelConfigSummary.self, from: encoded)

    #expect(decoded == summary)
  }

  @Test func snapshotRoundTripsConfigLibraryAndActiveID() throws {
    let date = Date(timeIntervalSince1970: fixedConfigEpoch)
    let snapshot = TunnelDaemonStatusSnapshot(
      configLibrary: [
        TunnelConfigSummary(id: configIDOne, name: "Home", createdAt: date),
        TunnelConfigSummary(id: configIDTwo, name: "Work", createdAt: date),
      ],
      activeConfigID: configIDTwo
    )

    let encoded = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(TunnelDaemonStatusSnapshot.self, from: encoded)

    #expect(decoded.configLibrary?.count == 2)
    #expect(decoded.activeConfigID == configIDTwo)
    #expect(decoded.configLibrary?.first?.name == "Home")
  }

  @Test func snapshotRenderedOutputListsConfigLibrary() {
    let date = Date(timeIntervalSince1970: fixedConfigEpoch)
    let snapshot = TunnelDaemonStatusSnapshot(
      configLibrary: [TunnelConfigSummary(id: configIDOne, name: "Home", createdAt: date)],
      activeConfigID: configIDOne
    )

    let output = snapshot.renderedOutput

    #expect(output.contains("configs=1"))
    #expect(output.contains("config.\(configIDOne.uuidString)=Home active"))
  }

  @Test func cliParseConfigsList() throws {
    let action = try TunnelControlCLIAction.parse(arguments: ["configs", "list"])

    #expect(action == .configs(.list))
  }

  @Test func cliParseConfigsActivateRequiresReference() {
    #expect(throws: (any Error).self) {
      try TunnelControlCLIAction.parse(arguments: ["configs", "activate"])
    }
  }

  @Test func cliParseConfigsRenameTakesIDAndName() throws {
    let action = try TunnelControlCLIAction.parse(
      arguments: ["configs", "rename", configIDOne.uuidString, "Home"])

    #expect(action == .configs(.rename(id: configIDOne, name: "Home")))
  }

  @Test func cliParseConfigsRenameRejectsNonUUID() {
    #expect(throws: (any Error).self) {
      try TunnelControlCLIAction.parse(arguments: ["configs", "rename", "not-a-uuid", "Home"])
    }
  }

  @Test func cliExecutorConfigsListReportsEmptyLibrary() async throws {
    let client = FakeTunnelControlClient()

    let output = try await runCLI(.configs(.list), on: client)

    #expect(output == "no configs")
  }

  @Test func cliExecutorConfigsActivateResolvesByNameThenActivates() async throws {
    let client = FakeTunnelControlClient()
    let directory = FileManager.default.temporaryDirectory
    let url = directory.appendingPathComponent("home-\(UUID().uuidString).conf")
    try Data("[Interface]\n".utf8).write(to: url, options: .atomic)
    defer {
      do {
        try FileManager.default.removeItem(at: url)
      } catch {
        logger.error(
          """
          temp config cleanup failed \
          details=\(String(describing: error), privacy: .public) recovery=ignore
          """
        )
      }
    }

    _ = try await runCLI(.configs(.importFile(path: url.path)), on: client)
    let importedName = url.deletingPathExtension().lastPathComponent
    client.events.removeAll()

    let output = try await runCLI(.configs(.activate(reference: importedName)), on: client)

    #expect(client.events.contains("activateConfig"))
    #expect(output.contains(importedName))
    #expect(output.contains("(active)"))
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
  // The egress roster the CLI lists and selects from. The id is a numeric token like
  // the real `String(UInt64)` ids, so `select` resolves by index rather than by id.
  var connectedPeersOverride: [ConnectedPeer]?
  let connectedRoster = [
    ConnectedPeer(id: "13452847362910", name: "Alex iPhone", isSelected: false)
  ]
  let selectedStatusSnapshot = TunnelDaemonStatusSnapshot(
    running: true,
    connectedPeers: [
      ConnectedPeer(id: "13452847362910", name: "Alex iPhone", isSelected: true)
    ]
  )
  // The config library the configs subcommands list, resolve, and mutate against.
  var configs: [TunnelConfigSummary] = []
  var activeConfigID: UUID?
  private let fixedConfigDate = Date(timeIntervalSince1970: fixedConfigEpoch)

  private func libraryStatus() -> TunnelDaemonStatusSnapshot {
    TunnelDaemonStatusSnapshot(
      connectedPeers: connectedPeersOverride ?? connectedRoster,
      configLibrary: configs,
      activeConfigID: activeConfigID
    )
  }

  func status() async -> TunnelDaemonStatusSnapshot {
    await Task.yield()
    events.append("status")
    return libraryStatus()
  }

  func check() async -> TunnelEnvironmentReport {
    await Task.yield()
    events.append("check")
    return TunnelEnvironmentReport()
  }

  func startPairing() async -> TunnelDaemonStatusSnapshot {
    await Task.yield()
    events.append("startPairing")
    return libraryStatus()
  }

  func startRelay() async -> TunnelDaemonStatusSnapshot {
    await Task.yield()
    events.append("startRelay")
    return libraryStatus()
  }

  func startTunnel(settings: TunnelStartSettings) async -> TunnelDaemonStatusSnapshot {
    await Task.yield()
    events.append("startTunnel")
    _ = settings
    return TunnelDaemonStatusSnapshot()
  }

  func reloadTunnel(settings: TunnelStartSettings) async -> TunnelDaemonStatusSnapshot {
    await Task.yield()
    events.append("reloadTunnel")
    _ = settings
    return TunnelDaemonStatusSnapshot()
  }

  func validateConfig(text: String) async {
    await Task.yield()
    events.append("validateConfig")
    _ = text
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
    return listedDiscoverySnapshot
  }

  func selectRelayService(serviceID: String) async -> TunnelDiscoverySnapshot {
    await Task.yield()
    events.append("selectRelayService")
    #expect(serviceID == "relay-1")
    return listedDiscoverySnapshot
  }

  func selectEgressPeer(peerID: String) async -> TunnelDaemonStatusSnapshot {
    await Task.yield()
    events.append("selectEgressPeer")
    #expect(peerID == "13452847362910")
    return selectedStatusSnapshot
  }

  func setRoutingEnabled(_ enabled: Bool) async -> TunnelDaemonStatusSnapshot {
    await Task.yield()
    events.append("setRoutingEnabled")
    _ = enabled
    return libraryStatus()
  }

  func importConfig(name: String, text: String) async -> TunnelDaemonStatusSnapshot {
    await Task.yield()
    events.append("importConfig")
    _ = text
    let summary = TunnelConfigSummary(id: UUID(), name: name, createdAt: fixedConfigDate)
    configs.append(summary)
    activeConfigID = summary.id
    return libraryStatus()
  }

  func activateConfig(id: UUID) async -> TunnelDaemonStatusSnapshot {
    await Task.yield()
    events.append("activateConfig")
    activeConfigID = id
    return libraryStatus()
  }

  func setActiveConfig(id: UUID) async -> TunnelDaemonStatusSnapshot {
    await Task.yield()
    events.append("setActiveConfig")
    activeConfigID = id
    return libraryStatus()
  }

  func saveConfigEdit(id: UUID, text: String) async -> TunnelDaemonStatusSnapshot {
    await Task.yield()
    events.append("saveConfigEdit")
    _ = (id, text)
    return libraryStatus()
  }

  func renameConfig(id: UUID, name: String) async -> TunnelDaemonStatusSnapshot {
    await Task.yield()
    events.append("renameConfig")
    if let index = configs.firstIndex(where: { $0.id == id }) {
      configs[index].name = name
    }
    return libraryStatus()
  }

  func deleteConfig(id: UUID) async -> TunnelDaemonStatusSnapshot {
    await Task.yield()
    events.append("deleteConfig")
    configs.removeAll { $0.id == id }
    if activeConfigID == id {
      activeConfigID = nil
    }
    return libraryStatus()
  }

  func getConfigText(id: UUID) async -> String {
    await Task.yield()
    events.append("getConfigText")
    _ = id
    return "[Interface]\n"
  }
}

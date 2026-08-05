//
//  SmokeTunnelControlClient.swift
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
private let relayPort = 51_820
private let fixedConfigEpoch: TimeInterval = 1_717_200_000
private let fakeRelayBytesInScale: UInt64 = 32
private let fakeRelayBytesOutScale: UInt64 = 64

func runSmokeCLI(
  _ action: TunnelControlCLIAction,
  on client: SmokeTunnelControlClient,
  probeRunner: any SmokeProbeRunner = UnavailableSmokeProbeRunner()
) async throws -> String {
  logger.debug("test driving cli executor action")
  let executor = TunnelControlCLIExecutor(client: client, probeRunner: probeRunner)
  return try await executor.run(action: action)
}

// MARK: - RecordingSmokeProbeRunner

final class RecordingSmokeProbeRunner: SmokeProbeRunner, @unchecked Sendable {
  var commands: [[String]] = []

  func run(executable: String, arguments: [String]) {
    commands.append([executable] + arguments)
  }
}

func makeSmokeRelayService(
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

// MARK: - SmokeTunnelControlClient

final class SmokeTunnelControlClient: TunnelControlClientProtocol, @unchecked Sendable {
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
      makeSmokeRelayService(
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
  private var tunnelStarted = false
  private var statusCallsAfterStart = 0

  private func libraryStatus() -> TunnelDaemonStatusSnapshot {
    if tunnelStarted {
      statusCallsAfterStart += 1
      let tick = UInt64(statusCallsAfterStart)
      return TunnelDaemonStatusSnapshot(
        running: true,
        routeState: .installed,
        macCounters: TunnelCounters(
          wireGuardDatagramsFromMac: tick,
          wireGuardDatagramsToMac: tick,
          wireGuardDatagramsFromServer: tick,
          relayBytesIn: tick &* fakeRelayBytesInScale,
          relayBytesOut: tick &* fakeRelayBytesOutScale
        ),
        connectedPeers: connectedPeersOverride ?? connectedRoster,
        configLibrary: configs,
        activeConfigID: activeConfigID
      )
    }
    return TunnelDaemonStatusSnapshot(
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
    tunnelStarted = true
    return TunnelDaemonStatusSnapshot(
      running: true,
      routeState: .installed,
      macCounters: TunnelCounters(),
      connectedPeers: connectedPeersOverride ?? connectedRoster
    )
  }

  func reloadTunnel(settings: TunnelStartSettings) async -> TunnelDaemonStatusSnapshot {
    await Task.yield()
    events.append("reloadTunnel")
    _ = settings
    tunnelStarted = true
    return libraryStatus()
  }

  func validateConfig(text: String) async {
    await Task.yield()
    events.append("validateConfig")
    _ = text
  }

  func stopTunnel() async -> TunnelDaemonStatusSnapshot {
    await Task.yield()
    events.append("stopTunnel")
    tunnelStarted = false
    statusCallsAfterStart = 0
    return TunnelDaemonStatusSnapshot(
      connectedPeers: connectedPeersOverride ?? connectedRoster,
      configLibrary: configs,
      activeConfigID: activeConfigID
    )
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

  func importConfig(
    name: String, text: String, activate: Bool
  ) async -> TunnelDaemonStatusSnapshot {
    await Task.yield()
    events.append("importConfig")
    _ = text
    let summary = TunnelConfigSummary(id: UUID(), name: name, createdAt: fixedConfigDate)
    configs.append(summary)
    if activate {
      activeConfigID = summary.id
    }
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

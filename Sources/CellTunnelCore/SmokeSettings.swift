//
//  SmokeSettings.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-22.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation
import Network

private let logger = CellTunnelLog.logger(category: .daemon)
private let smokeIPv4ProbeHost = "208.67.222.222"
private let smokeIPv6ProbeHost = "2620:119:35::35"
private let smokePingCount = "5"
private let smokeRouteWaitTimeoutSeconds: TimeInterval = 30
private let smokePeerWaitTimeoutSeconds: TimeInterval = 30
private let smokeRoutePollIntervalSeconds: TimeInterval = 0.5
private let ipv4BitWidth = 32
private let ipv6BitWidth = 128
private let ipv6ByteCount = 16
private let bitsPerByte = 8
private let fullByteMask: UInt8 = 0xff

// MARK: - SmokeSettings

public struct SmokeSettings: Equatable, Sendable {
  public var wireGuardConfigPath: String
  public var peerReference: String
  public var relayEndpoint: TunnelRelayEndpoint?

  public init(
    wireGuardConfigPath: String,
    peerReference: String,
    relayEndpoint: TunnelRelayEndpoint? = nil
  ) {
    self.wireGuardConfigPath = wireGuardConfigPath
    self.peerReference = peerReference
    self.relayEndpoint = relayEndpoint
  }
}

// MARK: - SmokeProbeRunner

/// Runs shell probes for `celltunnelctl smoke`. The macOS CLI supplies a Process-backed
/// runner; tests inject a fake so they never hit the network.
public protocol SmokeProbeRunner: Sendable {
  func run(executable: String, arguments: [String]) throws
}

// MARK: - UnavailableSmokeProbeRunner

/// Default runner for non-CLI call sites. Smoke always injects a real runner from
/// `celltunnelctl` or from tests.
public struct UnavailableSmokeProbeRunner: SmokeProbeRunner {
  public init() {
    // Marker init so the empty-body lint stays quiet for this intentional stub.
  }

  public func run(executable: String, arguments: [String]) throws {
    _ = (executable, arguments)
    throw TunnelDaemonError.transportFailure(
      "smoke probes require a SmokeProbeRunner from celltunnelctl")
  }
}

// MARK: - TunnelControlCLIExecutor

extension TunnelControlCLIExecutor {
  func runSmoke(_ settings: SmokeSettings) async throws -> String {
    var sections: [String] = []

    try verifySmokeConfigCoversProbeHosts(path: settings.wireGuardConfigPath)

    let status = try await client.status()
    sections.append("== status ==\n\(status.renderedOutput)")

    // Ensure the pairing listener is up before peers can dial in on a fresh agent.
    let pairingStatus = try await client.startPairing()
    sections.append("== pairing ==\n\(pairingStatus.renderedOutput)")

    let readyPeers = try await waitForConnectedPeers(minimumIndex: settings.peerReference)
    let peerListing = renderPeerListing(peers: readyPeers)
    sections.append("== peers ==\n\(peerListing)")

    let selectOutput = try await selectPeer(reference: settings.peerReference)
    sections.append("== select ==\n\(selectOutput)")

    let startSettings = TunnelStartSettings(
      wireGuardConfigPath: settings.wireGuardConfigPath,
      relayEndpoint: settings.relayEndpoint
    )
    // Stop first so startTunnel cannot take the already-hosted fast path that leaves
    // the saved VPN profile on a prior config stamp while only the live provider updates.
    let stopStatus = try await client.stopTunnel()
    sections.append("== stop ==\n\(stopStatus.renderedOutput)")

    let startStatus = try await client.startTunnel(settings: startSettings)
    sections.append("== start ==\n\(startStatus.renderedOutput)")

    let readyStatus = try await waitForInstalledRoutes()
    if let drift = readyStatus.configDrift, !drift.isEmpty {
      throw TunnelDaemonError.transportFailure(
        "smoke refused to probe while config drift is present: \(drift)")
    }
    sections.append("== routes ==\n\(readyStatus.renderedOutput)")

    let probeSummaries = try await runConnectivityProbes()
    sections.append("== probes ==\n\(probeSummaries.joined(separator: "\n"))")

    let finalStatus = try await client.status()
    if let drift = finalStatus.configDrift, !drift.isEmpty {
      throw TunnelDaemonError.transportFailure(
        "smoke finished probes with config drift present: \(drift)")
    }
    guard finalStatus.running, finalStatus.routeState == .installed else {
      throw TunnelDaemonError.transportFailure(
        """
        smoke finished probes without routes=installed \
        (running=\(finalStatus.running) routes=\(finalStatus.routeState.rawValue))
        """
      )
    }
    return sections.joined(separator: "\n")
  }

  private func verifySmokeConfigCoversProbeHosts(path: String) throws {
    let expanded = (path as NSString).expandingTildeInPath
    let text = try String(contentsOfFile: expanded, encoding: .utf8)
    let config = try WireGuardConfigParser.parse(text)
    let allowedIPs = config.peer.allowedIPs
    // Default routes can black-hole the Mac if the relay stalls, so smoke requires
    // scoped prefixes that still cover both OpenDNS probe hosts.
    if allowedIPs.contains(where: { $0.prefixLength == 0 }) {
      throw TunnelDaemonError.usage(
        """
        smoke --config AllowedIPs must not include default routes \
        (0.0.0.0/0 or ::/0); use scoped prefixes that cover both probe hosts
        """
      )
    }
    guard prefixesCover(allowedIPs, host: smokeIPv4ProbeHost, family: .ipv4) else {
      throw TunnelDaemonError.usage(
        "smoke --config AllowedIPs must cover \(smokeIPv4ProbeHost) with a scoped prefix"
      )
    }
    guard prefixesCover(allowedIPs, host: smokeIPv6ProbeHost, family: .ipv6) else {
      throw TunnelDaemonError.usage(
        "smoke --config AllowedIPs must cover \(smokeIPv6ProbeHost) with a scoped prefix"
      )
    }
  }

  private func prefixesCover(
    _ prefixes: [AddressPrefix],
    host: String,
    family: AddressFamily
  ) -> Bool {
    for prefix in prefixes where prefix.family == family {
      if prefixContains(prefix, host: host) {
        return true
      }
    }
    return false
  }

  private func prefixContains(_ prefix: AddressPrefix, host: String) -> Bool {
    // Default routes are rejected before coverage checks; never treat /0 as a match.
    if prefix.prefixLength == 0 {
      return false
    }
    switch prefix.family {
    case .ipv4:
      guard let hostAddress = IPv4Address(host),
        let networkAddress = IPv4Address(prefix.address)
      else {
        return false
      }
      let hostValue = ipv4Value(hostAddress)
      let networkValue = ipv4Value(networkAddress)
      let shift = ipv4BitWidth - min(max(prefix.prefixLength, 0), ipv4BitWidth)
      let mask = shift == ipv4BitWidth ? UInt32(0) : UInt32.max << shift
      return (hostValue & mask) == (networkValue & mask)
    case .ipv6:
      guard let hostAddress = IPv6Address(host),
        let networkAddress = IPv6Address(prefix.address)
      else {
        return false
      }
      return ipv6(hostAddress, isCoveredBy: networkAddress, prefixLength: prefix.prefixLength)
    }
  }

  private func ipv4Value(_ address: IPv4Address) -> UInt32 {
    address.rawValue.withUnsafeBytes { buffer in
      buffer.load(as: UInt32.self).bigEndian
    }
  }

  private func ipv6(
    _ host: IPv6Address,
    isCoveredBy network: IPv6Address,
    prefixLength: Int
  ) -> Bool {
    let hostBytes = Array(host.rawValue)
    let networkBytes = Array(network.rawValue)
    guard hostBytes.count == ipv6ByteCount, networkBytes.count == ipv6ByteCount else {
      return false
    }
    let clampedPrefix = min(max(prefixLength, 0), ipv6BitWidth)
    var remaining = clampedPrefix
    var index = 0
    while remaining >= bitsPerByte {
      if hostBytes[index] != networkBytes[index] {
        return false
      }
      index += 1
      remaining -= bitsPerByte
    }
    if remaining == 0 {
      return true
    }
    let mask = fullByteMask << (bitsPerByte - remaining)
    return (hostBytes[index] & mask) == (networkBytes[index] & mask)
  }

  private func waitForConnectedPeers(minimumIndex: String) async throws -> [ConnectedPeer] {
    guard let requiredIndex = Int(minimumIndex), requiredIndex >= 1 else {
      throw TunnelDaemonError.usage("smoke --peer requires a 1-based index from `peers`")
    }
    let deadline = Date().addingTimeInterval(smokePeerWaitTimeoutSeconds)
    var latest = try await client.status()
    var peers = latest.connectedPeers ?? []
    while Date() < deadline {
      if peers.count >= requiredIndex {
        return peers
      }
      await smokePollDelay(seconds: smokeRoutePollIntervalSeconds)
      latest = try await client.status()
      peers = latest.connectedPeers ?? []
    }
    throw TunnelDaemonError.transportFailure(
      """
      smoke timed out waiting for at least \(requiredIndex) connected peer(s) \
      (have \(peers.count))
      """
    )
  }

  private func waitForInstalledRoutes() async throws -> TunnelDaemonStatusSnapshot {
    let deadline = Date().addingTimeInterval(smokeRouteWaitTimeoutSeconds)
    var latest = try await client.status()
    while Date() < deadline {
      if let drift = latest.configDrift, !drift.isEmpty {
        throw TunnelDaemonError.transportFailure(
          "smoke refused to wait for routes while config drift is present: \(drift)")
      }
      if latest.running, latest.routeState == .installed {
        return latest
      }
      await smokePollDelay(seconds: smokeRoutePollIntervalSeconds)
      latest = try await client.status()
    }
    if let drift = latest.configDrift, !drift.isEmpty {
      throw TunnelDaemonError.transportFailure(
        """
        smoke timed out waiting for routes=installed with config drift present: \(drift) \
        (running=\(latest.running) routes=\(latest.routeState.rawValue))
        """
      )
    }
    throw TunnelDaemonError.transportFailure(
      """
      smoke timed out waiting for routes=installed \
      (running=\(latest.running) routes=\(latest.routeState.rawValue))
      """
    )
  }

  private struct SmokeTrafficSample: Equatable {
    var outbound: UInt64
    var inbound: UInt64
  }

  private func smokeTrafficSample(_ snapshot: TunnelDaemonStatusSnapshot) -> SmokeTrafficSample {
    let counters = snapshot.macCounters ?? TunnelCounters()
    return SmokeTrafficSample(
      outbound: counters.wireGuardDatagramsFromMac &+ counters.relayBytesOut,
      inbound: counters.wireGuardDatagramsToMac
        &+ counters.wireGuardDatagramsFromServer
        &+ counters.relayBytesIn
    )
  }

  private func smokePollDelay(seconds: TimeInterval) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
        continuation.resume()
      }
    }
  }

  private func runConnectivityProbes() async throws -> [String] {
    let probes: [(String, [String])] = [
      ("ping", ["-c", smokePingCount, smokeIPv4ProbeHost]),
      // `-s 16` avoids false loss when upstream IPv6 transit drops default-size ICMPv6.
      ("ping6", ["-c", smokePingCount, "-s", "16", smokeIPv6ProbeHost]),
      ("curl", ["-v", "https://\(smokeIPv4ProbeHost)/"]),
      ("curl", ["-v", "-g", "https://[\(smokeIPv6ProbeHost)]/"]),
    ]
    var summaries: [String] = []
    for (executable, arguments) in probes {
      logger.notice(
        "smoke probe executable=\(executable, privacy: .public) argumentCount=\(arguments.count, privacy: .public)"
      )
      let beforeStatus = try await client.status()
      let trafficBefore = smokeTrafficSample(beforeStatus)
      try probeRunner.run(executable: executable, arguments: arguments)
      let afterStatus = try await client.status()
      let trafficAfter = smokeTrafficSample(afterStatus)
      guard trafficAfter.outbound > trafficBefore.outbound,
        trafficAfter.inbound > trafficBefore.inbound
      else {
        let rendered = ([executable] + arguments).joined(separator: " ")
        throw TunnelDaemonError.transportFailure(
          """
          smoke probe did not show bidirectional tunnel counter growth: \(rendered) \
          (outbound \(trafficBefore.outbound)->\(trafficAfter.outbound), \
          inbound \(trafficBefore.inbound)->\(trafficAfter.inbound)); \
          traffic may have bypassed the tunnel
          """
        )
      }
      summaries.append(
        """
        ok \(executable) outbound=\(trafficBefore.outbound)->\(trafficAfter.outbound) \
        inbound=\(trafficBefore.inbound)->\(trafficAfter.inbound)
        """
      )
    }
    return summaries
  }
}

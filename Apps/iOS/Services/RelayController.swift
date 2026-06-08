//
//  RelayController.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-31.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Observation

private let logger = CellTunnelLog.logger(category: .relay)
private let pollIntervalSeconds: Double = 1
private let relayStoppedStateText = "Stopped"
// Status polls an unconfirmed routing request waits for the agent to apply before
// the switch reverts to the real state, so a request that never lands cannot leave
// the spinner spinning forever. At the 1s poll cadence this is an 8s budget.
private let routeIntentTimeoutPolls = 8

// MARK: - RelayStatusSample

/// One normalized reading of relay status that the shared controller publishes to
/// the views. Each platform backend fills it from its own source: the iPhone from
/// its tunnel extension, the Mac from the agent.
struct RelayStatusSample: Sendable {
  var isRunning: Bool
  var relayStateDescription: String
  var connectedPeerName: String?
  var cellularPath: CellularPathSnapshot
  var counters: TunnelCounters
  var lastError: String?
  /// Whether the program routes are installed, which the screen reads as routing
  /// (installed) versus passthrough (not installed).
  var routeState: TunnelRouteState
  /// Whether a WireGuard peer is configured, which gates the connected states.
  var peerState: TunnelPeerState
  /// Whether a tunnel profile is saved, the gate between the install-tunnel setup
  /// tier and the running states. Derived from `peerState` and overridable by a
  /// backend that knows its own manager presence.
  var isTunnelInstalled: Bool
  /// The peers discovery currently sees, the selected peer's id, and the discovery
  /// phase, surfaced from the snapshot's discovery section.
  var discoveredPeers: [TunnelRelayService]
  var selectedPeerID: String?
  var discoveryPhase: TunnelDiscoveryPhase
  /// The relay tunnel protocol name shown on the status `Protocol` row, set by the
  /// WireGuard producers, or `nil` before a snapshot names it.
  var relayProtocol: String?
  /// The carrying link's raw interface identifier and transport class, shown on the
  /// `Connected via` row.
  var localLinkInterfaceName: String?
  var localLinkClass: RelayLinkClass?
  /// This device's and the peer's public addresses, shown under `Device / Public`
  /// and `Peer / Public`.
  var devicePublicAddresses: AddressPair
  var peerPublicAddresses: AddressPair
  /// The carrying link's local and peer addresses, shown under `Connection`.
  var localLinkAddresses: AddressPair
  var peerLinkAddresses: AddressPair
  /// The configured WireGuard endpoint hostname, shown as the relay host.
  var relayHost: String?
  /// The WireGuard server's IPv4 address, the endpoint hostname resolved to A.
  var relayServerIPv4Address: String?
  /// The WireGuard server's IPv6 address, the endpoint hostname resolved to AAAA.
  var relayServerIPv6Address: String?

  /// Maps a daemon status snapshot to one sample. Every backend builds its sample
  /// here, so the snapshot-to-sample mapping lives in one place; a backend applies
  /// only its own override afterward. Counters read from whichever side the snapshot
  /// carries, so the one mapping serves the iPhone and the Mac.
  init(snapshot: TunnelDaemonStatusSnapshot) {
    isRunning = snapshot.running
    relayStateDescription = snapshot.relayState ?? relayStoppedStateText
    connectedPeerName = snapshot.connectedPeerName
    cellularPath = snapshot.cellularPath ?? CellularPathSnapshot()
    counters = snapshot.phoneCounters ?? snapshot.macCounters ?? TunnelCounters()
    lastError = snapshot.lastError
    routeState = snapshot.routeState
    peerState = snapshot.peerState
    isTunnelInstalled = snapshot.peerState != .notSelected
    discoveredPeers = snapshot.discovery.services
    selectedPeerID = snapshot.discovery.selectedServiceID
    discoveryPhase = snapshot.discovery.phase
    relayProtocol = snapshot.relayProtocol
    localLinkInterfaceName = snapshot.localLinkInterfaceName
    localLinkClass = snapshot.localLinkClass
    devicePublicAddresses = snapshot.devicePublicAddresses ?? .empty
    peerPublicAddresses = snapshot.peerPublicAddresses ?? .empty
    localLinkAddresses = snapshot.localLinkAddresses ?? .empty
    peerLinkAddresses = snapshot.peerLinkAddresses ?? .empty
    relayHost = snapshot.relayHost
    relayServerIPv4Address = snapshot.relayServerIPv4Address
    relayServerIPv6Address = snapshot.relayServerIPv6Address
  }
}

// MARK: - RelayControlBackend

/// The platform-specific source behind the shared relay UI. The iPhone backend
/// drives the on-device relay. The Mac backend reads the agent. The controller
/// owns the poll cadence and the published state, so a backend only brings its
/// session up or down and answers one status reading at a time.
@MainActor
protocol RelayControlBackend {
  /// Brings the platform relay session up. The iPhone creates and starts its
  /// tunnel. The Mac leaves the agent's tunnel untouched.
  func start() async

  /// One status reading, or `nil` when the source is briefly unavailable.
  func sample() async -> RelayStatusSample?

  /// Sets the routing choice: on installs the program routes, off returns to
  /// passthrough. The choice reaches the agent, which owns the routes, over the
  /// platform's control path.
  func setRouting(enabled: Bool) async

  /// Selects the discovered peer to connect to. The Mac forwards the choice to the
  /// agent; the iPhone records it and dials that peer over the control link.
  func selectPeer(id: String) async

  /// Installs the tunnel profile from an imported configuration. The Mac hands the
  /// config to the agent's start path; the iPhone saves its own tunnel manager.
  func installTunnel(configURL: URL) async
}

// MARK: - RelayController

/// Drives the shared relay screens. It holds the published status the views bind
/// to and runs one status poll per second against a platform backend, so the
/// views never branch on platform. The iPhone backend reads the on-device relay;
/// the Mac backend reads the agent.
@MainActor
@Observable
final class RelayController {
  private let backend: any RelayControlBackend
  private let installState: InstallationState
  private let deviceProbe: DeviceEgressProbe?
  private var pollTask: Task<Void, Never>?
  private var throughput: ThroughputCalculator
  private var lifetimeStore: LifetimeDataStore
  // The latest device egress and public address from the backend snapshot and from
  // the app's own probe, kept apart so one recompute picks the right source: the
  // backend's values while the relay carries the device's traffic, the probe's
  // otherwise.
  private var backendCellularPath = CellularPathSnapshot()
  private var backendDevicePublicAddresses = AddressPair.empty
  private var probeCellularPath = CellularPathSnapshot()
  private var probeDevicePublicAddresses = AddressPair.empty

  var isRunning = false
  var connectedPeerName: String?
  var cellularPath = CellularPathSnapshot()
  var counters = TunnelCounters()
  var lifetimeTransferredBytes: UInt64 = 0
  var lifetimeReceivedBytes: UInt64 = 0
  var lifetimeTotalBytes: UInt64 = 0
  var uploadMbps: Double = 0
  var downloadMbps: Double = 0
  var lastError: String?
  var relayStateDescription = relayStoppedStateText
  var routeState: TunnelRouteState = .notInstalled
  var peerState: TunnelPeerState = .notSelected
  /// The routing value the user last requested, held while a request is pending so
  /// the switch shows the requested state until the agent's real `routeState`
  /// confirms it. Only meaningful while `routeIntentPollsRemaining` is positive.
  private var requestedRouting = false
  // Status polls left before an unconfirmed routing request reverts to the real
  // state; a positive value means a request is pending, counted down each poll.
  private var routeIntentPollsRemaining = 0
  /// Whether the background agent is installed, the gate to the install-agent setup
  /// tier. Always true on the iPhone, where there is no separate agent; on the Mac
  /// it tracks the install state.
  var isAgentInstalled = true
  /// Whether a tunnel profile is saved, the gate to the install-tunnel setup tier.
  var isTunnelInstalled = false
  /// Whether the agent install is registered but awaiting the user's Login Items
  /// approval, surfaced so the setup screen can route them to System Settings.
  var isAgentApprovalPending = false
  /// The peers discovery currently sees, the selected peer's id, and the discovery
  /// phase, the inputs to the peers list and the no-peer states.
  var discoveredPeers: [TunnelRelayService] = []
  var selectedPeerID: String?
  var discoveryPhase: TunnelDiscoveryPhase = .stopped
  /// The relay tunnel protocol name shown on the status `Protocol` row, read from
  /// the snapshot's producer rather than a hardcoded literal.
  var relayProtocol: String?
  var localLinkInterfaceName: String?
  var localLinkClass: RelayLinkClass?
  var localLinkAddresses = AddressPair.empty
  var peerLinkAddresses = AddressPair.empty
  var devicePublicAddresses = AddressPair.empty
  var peerPublicAddresses = AddressPair.empty
  var relayHost: String?
  var relayServerIPv4Address: String?
  var relayServerIPv6Address: String?

  init(
    backend: any RelayControlBackend,
    throughput: ThroughputCalculator,
    lifetimeStore: LifetimeDataStore,
    installState: InstallationState = InstallationState(),
    deviceProbe: DeviceEgressProbe? = nil
  ) {
    self.backend = backend
    self.throughput = throughput
    self.lifetimeStore = lifetimeStore
    self.installState = installState
    self.deviceProbe = deviceProbe
  }

  // MARK: - Lifecycle

  /// Brings the platform session up, starts the app's own egress probe, then starts
  /// the status poll.
  func start() async {
    logger.notice("relay controller start requested")
    startDeviceProbe()
    await backend.start()
    startPolling()
  }

  // Wires the app's egress probe to the device-value recompute and starts it for
  // the app lifetime, so the `Device` rows show the app's own egress before the
  // relay runs and whenever the relay does not carry the device's traffic.
  private func startDeviceProbe() {
    guard let deviceProbe else {
      logger.notice("relay controller device probe absent; skipping start")
      return
    }
    deviceProbe.onUpdate = { [weak self] path, publicAddresses in
      Task { @MainActor [weak self] in
        self?.applyProbe(cellularPath: path, publicAddresses: publicAddresses)
      }
    }
    deviceProbe.start()
    logger.notice("relay controller device probe started")
  }

  private func applyProbe(cellularPath: CellularPathSnapshot, publicAddresses: AddressPair) {
    probeCellularPath = cellularPath
    probeDevicePublicAddresses = publicAddresses
    recomputeDeviceValues()
  }

  // Picks the device egress and public address source: the backend snapshot while
  // the relay runs and carries a value, otherwise the app's own probe. The
  // `Interface` rows follow from the chosen `cellularPath`.
  private func recomputeDeviceValues() {
    if isRunning, backendCellularPath.interfaceName != nil {
      cellularPath = backendCellularPath
    } else {
      cellularPath = probeCellularPath
    }
    if isRunning, !backendDevicePublicAddresses.isEmpty {
      devicePublicAddresses = backendDevicePublicAddresses
    } else {
      devicePublicAddresses = probeDevicePublicAddresses
    }
  }

  /// Suspends the status poll without touching the session, for backgrounding.
  func suspendPolling() {
    logger.notice("relay controller suspending status poll")
    stopPolling()
  }

  /// Resumes the status poll after foregrounding.
  func resumePolling() {
    logger.notice("relay controller resuming status poll")
    startPolling()
  }

  // MARK: - Poll loop

  private func startPolling() {
    pollTask?.cancel()
    throughput.reset()
    logger.notice("relay controller status poll starting")
    pollTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else {
          return
        }
        if let sample = await backend.sample() {
          apply(sample)
          refreshInstallState(agentReachable: true)
        } else {
          refreshInstallState(agentReachable: false)
        }
        guard !Task.isCancelled else {
          return
        }
        await Self.delayBetweenPolls()
      }
    }
  }

  private func stopPolling() {
    logger.notice("relay controller status poll stopping")
    pollTask?.cancel()
    pollTask = nil
  }

  private func apply(_ sample: RelayStatusSample) {
    isRunning = sample.isRunning
    connectedPeerName = sample.connectedPeerName
    backendCellularPath = sample.cellularPath
    counters = sample.counters
    let lifetime = lifetimeStore.totals(
      sessionTransferred: sample.counters.relayBytesIn,
      sessionReceived: sample.counters.relayBytesOut
    )
    lifetimeTransferredBytes = lifetime.transferred
    lifetimeReceivedBytes = lifetime.received
    lifetimeTotalBytes = lifetime.total
    lastError = sample.lastError
    relayStateDescription = sample.relayStateDescription
    routeState = sample.routeState
    reconcileRouteIntent()
    peerState = sample.peerState
    isTunnelInstalled = sample.isTunnelInstalled
    discoveredPeers = sample.discoveredPeers
    selectedPeerID = sample.selectedPeerID
    discoveryPhase = sample.discoveryPhase
    relayProtocol = sample.relayProtocol
    localLinkInterfaceName = sample.localLinkInterfaceName
    localLinkClass = sample.localLinkClass
    localLinkAddresses = sample.localLinkAddresses
    peerLinkAddresses = sample.peerLinkAddresses
    backendDevicePublicAddresses = sample.devicePublicAddresses
    peerPublicAddresses = sample.peerPublicAddresses
    relayHost = sample.relayHost
    relayServerIPv4Address = sample.relayServerIPv4Address
    relayServerIPv6Address = sample.relayServerIPv6Address
    recomputeDeviceValues()
    let rate = throughput.update(with: sample.counters)
    uploadMbps = rate.upload
    downloadMbps = rate.download
    logger.debug("relay controller sample applied running=\(self.isRunning, privacy: .public)")
  }

  // Refreshes the agent install state each poll, so the install-agent setup tier
  // appears on a Mac with no agent and clears once the agent answers or is enabled.
  private func refreshInstallState(agentReachable: Bool) {
    installState.refresh(agentReachable: agentReachable)
    isAgentInstalled = installState.isAgentInstalled
    isAgentApprovalPending = installState.isApprovalPending
  }

  // MARK: - Routing control

  /// Requests routing (on) or passthrough (off) for the `Route traffic` switch.
  /// The backend forwards the choice to the agent, which installs or withdraws
  /// the program routes. The displayed routing-versus-passthrough state reads from
  /// the real `routeState` in the next status snapshot.
  /// The routing value the switch shows: the pending request while one is in
  /// flight, otherwise the agent's confirmed route state.
  var displayedRouting: Bool {
    isRouteRequestPending ? requestedRouting : (routeState == .installed)
  }

  /// Whether a routing request is awaiting the agent's confirmation, so the screen
  /// shows a spinner beside the switch.
  var isRouteRequestPending: Bool {
    routeIntentPollsRemaining > 0
  }

  func setRouteTraffic(enabled: Bool) async {
    logger.notice(
      "relay controller route traffic requested enabled=\(enabled, privacy: .public)")
    requestedRouting = enabled
    routeIntentPollsRemaining = routeIntentTimeoutPolls
    await backend.setRouting(enabled: enabled)
  }

  // Clears the optimistic routing intent once the agent's real route state matches
  // it, or after the poll budget elapses, so the switch follows the confirmed state
  // and a request the agent never applies snaps back rather than spinning forever.
  private func reconcileRouteIntent() {
    guard isRouteRequestPending else {
      return
    }
    if (routeState == .installed) == requestedRouting {
      routeIntentPollsRemaining = 0
      return
    }
    routeIntentPollsRemaining -= 1
    if routeIntentPollsRemaining <= 0 {
      logger.notice(
        "relay controller route request unconfirmed; reverting switch to real state")
    }
  }

  // MARK: - Peer selection

  /// Selects the discovered peer to connect to. The next status snapshot reflects
  /// the selection and, once the link is up, moves the screen to passthrough.
  func selectPeer(id: String) async {
    logger.notice("relay controller select peer id=\(id, privacy: .public)")
    await backend.selectPeer(id: id)
  }

  // MARK: - Setup actions

  /// Registers the background agent, the install-agent setup action. Mac only; the
  /// iPhone has no separate agent, so the install state holds it as always present.
  func installAgent() {
    logger.notice("relay controller install agent requested")
    installState.registerAgent()
  }

  /// Opens Login Items so the user can approve a registered-but-pending agent.
  func openLoginItems() {
    logger.notice("relay controller open login items requested")
    installState.openLoginItems()
  }

  /// Installs the tunnel profile from an imported configuration, the install-tunnel
  /// setup action. The backend hands it to the platform's start path.
  func installTunnel(configURL: URL) async {
    logger.notice("relay controller install tunnel requested")
    await backend.installTunnel(configURL: configURL)
  }

  /// Spaces polls without `Task.sleep` by resuming off a dispatch queue after the
  /// configured interval.
  private static func delayBetweenPolls() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.global(qos: .utility)
        .asyncAfter(deadline: .now() + pollIntervalSeconds) {
          continuation.resume()
        }
    }
  }

}

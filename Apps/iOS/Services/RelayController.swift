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
// Status polls an unconfirmed routing-off request waits for the agent to apply
// before the switch reverts to the real state, so a request that never lands cannot
// leave the spinner spinning forever. Turning off stops the relay at once, so the
// off budget is short; at the 1s poll cadence this is an 8s budget.
private let routeIntentTimeoutPolls = 8
// Turning on starts a relay session whose connect can take up to the session connect
// timeout (~30s), so the on budget is long enough to cover the connect and the
// spinner does not snap back to off mid-connect; at the 1s poll cadence this is a 32s
// budget.
private let routeConnectTimeoutPolls = 32

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
  /// The agent's routing intent, the shared value behind the Route traffic switch that
  /// both screens mirror, so the switch reads the same on the iPhone and the Mac
  /// regardless of the local interface running flag. A producer that predates the field
  /// sends nil, so the sample falls back to `routeState` (installed reads as on), and a
  /// mixed-version agent still shows the switch correctly.
  var routingIntentEnabled: Bool
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
  /// The iPhones currently dialed into the Mac agent, the roster the Mac selector
  /// lists and chooses egress through. Empty on the iPhone, which hosts no roster.
  var connectedPeers: [ConnectedPeer]
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
  /// The relay-link candidates on this side, shown on the local `Available
  /// Interfaces` row.
  var localAvailableLinks: [RelayLinkSummary]
  /// The candidates the peer reports about itself, shown on the peer
  /// `Available Interfaces` row.
  var peerAvailableLinks: [RelayLinkSummary]
  /// The configured WireGuard endpoint hostname, shown as the relay host.
  var relayHost: String?
  /// The WireGuard server's IPv4 address, the endpoint hostname resolved to A.
  var relayServerIPv4Address: String?
  /// The WireGuard server's IPv6 address, the endpoint hostname resolved to AAAA.
  var relayServerIPv6Address: String?
  /// The agent's config library as text-free summaries, shown in the Configs card.
  /// Empty from a producer with no library (iPhone, simulator, preview).
  var configLibrary: [TunnelConfigSummary]
  /// The id of the active config in `configLibrary`, the one the running tunnel uses.
  var activeConfigID: UUID?

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
    // An older agent omits the intent field; fall back to whether routes are installed
    // so a mixed-version agent still reads the switch correctly.
    let routesInstalledFallback = snapshot.routeState == .installed
    routingIntentEnabled = snapshot.routingIntentEnabled?.isEnabled ?? routesInstalledFallback
    peerState = snapshot.peerState
    isTunnelInstalled = snapshot.peerState != .notSelected
    discoveredPeers = snapshot.discovery.services
    selectedPeerID = snapshot.discovery.selectedServiceID
    discoveryPhase = snapshot.discovery.phase
    connectedPeers = snapshot.connectedPeers ?? []
    relayProtocol = snapshot.relayProtocol
    localLinkInterfaceName = snapshot.localLinkInterfaceName
    localLinkClass = snapshot.localLinkClass
    devicePublicAddresses = snapshot.devicePublicAddresses ?? .empty
    peerPublicAddresses = snapshot.peerPublicAddresses ?? .empty
    localLinkAddresses = snapshot.localLinkAddresses ?? .empty
    peerLinkAddresses = snapshot.peerLinkAddresses ?? .empty
    localAvailableLinks = snapshot.localAvailableLinks ?? []
    peerAvailableLinks = snapshot.peerAvailableLinks ?? []
    relayHost = snapshot.relayHost
    relayServerIPv4Address = snapshot.relayServerIPv4Address
    relayServerIPv6Address = snapshot.relayServerIPv6Address
    configLibrary = snapshot.configLibrary ?? []
    activeConfigID = snapshot.activeConfigID
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
  /// tunnel. The Mac starts the control pairing path so the iPhone can appear in
  /// the peer roster; turning the Route traffic switch on then starts the relay.
  func start() async

  /// Reads the saved tunnel state fresh from the platform without saving anything;
  /// true when a usable tunnel configuration exists. The iPhone reads
  /// NetworkExtension preferences; the Mac, the simulator, and previews answer true
  /// because their setup gating comes from status samples.
  func tunnelProvisioned() async -> Bool

  /// One status reading, or `nil` when the source is briefly unavailable.
  func sample() async -> RelayStatusSample?

  /// Sets the routing choice: on installs the program routes, off returns to
  /// passthrough. The choice reaches the agent, which owns the routes, over the
  /// platform's control path.
  func setRouting(enabled: Bool) async

  /// Selects the discovered peer to connect to. The Mac forwards the choice to the
  /// agent; the iPhone records it and dials that peer over the control link.
  func selectPeer(id: String) async

  /// Selects which dialed-in iPhone the Mac routes egress through, by the roster id.
  /// Only the Mac backend acts on it; the iPhone hosts no roster, so its default is a
  /// no-op.
  func selectEgressPeer(id: String) async

  /// Whether this backend auto-dials the first discovered peer when none is selected,
  /// so the iPhone connects to its Mac with no picker. The Mac, which selects egress
  /// from its own roster instead, leaves this false.
  var autoSelectsDiscoveredPeer: Bool { get }

  /// Whether this backend's available peers come from the dialed-in roster rather than
  /// Bonjour discovery, so the status word reflects connected iPhones on the Mac. True
  /// only on the Mac; the iPhone, which browses for a Mac to dial, leaves this false.
  var usesEgressRoster: Bool { get }

  /// Installs the tunnel profile from an imported configuration. The Mac hands the
  /// config to the agent's start path; the iPhone saves its own tunnel manager.
  func installTunnel(configURL: URL) async

  /// Loads a stored config's secret text on demand, for the editor. The Mac fetches
  /// it from the agent; backends with no library answer `nil`.
  func loadConfigText(id: UUID) async -> String?

  /// Imports a WireGuard configuration file into this backend's config library.
  func importConfig(url: URL, name: String) async

  /// Makes a stored configuration the active relay configuration.
  func activateConfig(id: UUID) async

  /// Saves edited WireGuard configuration text for a stored configuration.
  func saveConfigEdit(id: UUID, text: String) async

  /// Deletes a stored configuration from this backend's config library.
  func deleteConfig(id: UUID) async
}

// MARK: - RelayControlBackend defaults

/// Defaults for the two capability flags: a backend that does not override them does
/// not auto-dial and hosts no egress roster. The Mac overrides the roster flag and the
/// iPhone backends override auto-dial. Egress selection itself has no default; each
/// backend implements its own `selectEgressPeer`, which the iPhone backends leave as a
/// no-op.
extension RelayControlBackend {
  var autoSelectsDiscoveredPeer: Bool {
    false
  }

  var usesEgressRoster: Bool {
    false
  }
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
  /// The agent's routing intent, the shared value behind the Route traffic switch. Both
  /// the iPhone and the Mac mirror it from the agent, so the switch reads the same on
  /// each rather than from a local running flag that differs per platform.
  var routingIntentEnabled = false
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
  /// The iPhones currently dialed into the Mac agent, the roster the Mac selector
  /// lists. Empty on the iPhone, which hosts no roster.
  var connectedPeers: [ConnectedPeer] = []
  // Guards the iPhone auto-dial so the first discovered Mac is selected once rather
  // than re-requested every poll while the selection lands.
  private var autoSelectInFlight = false
  /// The relay tunnel protocol name shown on the status `Protocol` row, read from
  /// the snapshot's producer rather than a hardcoded literal.
  var relayProtocol: String?
  var localLinkInterfaceName: String?
  var localLinkClass: RelayLinkClass?
  var localLinkAddresses = AddressPair.empty
  var peerLinkAddresses = AddressPair.empty
  /// The relay-link candidates on this side, shown on the local `Available
  /// Interfaces` row.
  var localAvailableLinks: [RelayLinkSummary] = []
  /// The candidates the peer reports about itself, shown on the peer
  /// `Available Interfaces` row.
  var peerAvailableLinks: [RelayLinkSummary] = []
  var devicePublicAddresses = AddressPair.empty
  /// Every address on the egress interface, recomputed off the render path once per
  /// poll so the `Interface` rows read a cached value rather than calling
  /// `getifaddrs` on every SwiftUI body evaluation.
  var interfaceAddresses = InterfaceAddressList.empty
  var peerPublicAddresses = AddressPair.empty
  var relayHost: String?
  var relayServerIPv4Address: String?
  var relayServerIPv6Address: String?
  /// The agent's config library mirrored from the status poll, the rows the Configs
  /// card lists, so the card reads the same source as the Relay tile and the two
  /// never diverge. Empty on the iPhone, which hosts no library.
  var configLibrary: [TunnelConfigSummary] = []
  /// The active config's id, mirrored from the same poll, the entry the card marks
  /// active and the running tunnel uses.
  var activeConfigID: UUID?

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

  /// Starts the relay only when a saved tunnel configuration is already approved.
  func prepare() async {
    logger.notice("relay controller prepare requested")
    let provisioned = await backend.tunnelProvisioned()
    if provisioned {
      await start()
    } else {
      isTunnelInstalled = false
      logger.notice("relay controller prepare found no saved tunnel")
    }
  }

  /// Refreshes saved tunnel presence and starts the relay when provisioned and idle.
  func refreshProvisioned() async {
    logger.notice("relay controller provisioned refresh requested")
    let provisioned = await backend.tunnelProvisioned()
    if !provisioned {
      isTunnelInstalled = false
      logger.notice("relay controller provisioned refresh found no saved tunnel")
      return
    }
    if pollTask == nil {
      await start()
    }
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
      assign(\.cellularPath, backendCellularPath)
    } else {
      assign(\.cellularPath, probeCellularPath)
    }
    if isRunning, !backendDevicePublicAddresses.isEmpty {
      assign(\.devicePublicAddresses, backendDevicePublicAddresses)
    } else {
      assign(\.devicePublicAddresses, probeDevicePublicAddresses)
    }
    let all = InterfaceAddressLookup.allAddresses(
      forInterface: cellularPath.interfaceName ?? "")
    assign(\.interfaceAddresses, all)
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
    assign(\.isRunning, sample.isRunning)
    assign(\.connectedPeerName, sample.connectedPeerName)
    assign(\.backendCellularPath, sample.cellularPath)
    assign(\.counters, sample.counters)
    let lifetime = lifetimeStore.totals(
      sessionTransferred: sample.counters.relayBytesIn,
      sessionReceived: sample.counters.relayBytesOut
    )
    assign(\.lifetimeTransferredBytes, lifetime.transferred)
    assign(\.lifetimeReceivedBytes, lifetime.received)
    assign(\.lifetimeTotalBytes, lifetime.total)
    assign(\.lastError, sample.lastError)
    assign(\.relayStateDescription, sample.relayStateDescription)
    assign(\.routeState, sample.routeState)
    assign(\.routingIntentEnabled, sample.routingIntentEnabled)
    reconcileRouteIntent()
    assign(\.peerState, sample.peerState)
    assign(\.isTunnelInstalled, sample.isTunnelInstalled)
    assign(\.discoveredPeers, sample.discoveredPeers)
    assign(\.selectedPeerID, sample.selectedPeerID)
    assign(\.discoveryPhase, sample.discoveryPhase)
    assign(\.connectedPeers, sample.connectedPeers)
    maybeAutoSelectPeer()
    assign(\.relayProtocol, sample.relayProtocol)
    assign(\.localLinkInterfaceName, sample.localLinkInterfaceName)
    assign(\.localLinkClass, sample.localLinkClass)
    assign(\.localLinkAddresses, sample.localLinkAddresses)
    assign(\.peerLinkAddresses, sample.peerLinkAddresses)
    assign(\.localAvailableLinks, sample.localAvailableLinks)
    assign(\.peerAvailableLinks, sample.peerAvailableLinks)
    assign(\.backendDevicePublicAddresses, sample.devicePublicAddresses)
    assign(\.peerPublicAddresses, sample.peerPublicAddresses)
    assign(\.relayHost, sample.relayHost)
    assign(\.relayServerIPv4Address, sample.relayServerIPv4Address)
    assign(\.relayServerIPv6Address, sample.relayServerIPv6Address)
    assign(\.configLibrary, sample.configLibrary)
    assign(\.activeConfigID, sample.activeConfigID)
    recomputeDeviceValues()
    let rate = throughput.update(with: sample.counters)
    assign(\.uploadMbps, rate.upload)
    assign(\.downloadMbps, rate.download)
    logger.debug("relay controller sample applied running=\(self.isRunning, privacy: .public)")
  }

  // Assigns only when the value changes, so each @Observable property notifies the
  // views on a real change rather than on every one-second status poll.
  private func assign<Value: Equatable>(
    _ keyPath: ReferenceWritableKeyPath<RelayController, Value>, _ newValue: Value
  ) {
    if self[keyPath: keyPath] != newValue {
      self[keyPath: keyPath] = newValue
    }
  }

  // Refreshes the agent install state each poll, so the install-agent setup tier
  // appears on a Mac with no agent and clears once the agent answers or is enabled.
  private func refreshInstallState(agentReachable: Bool) {
    installState.refresh(agentReachable: agentReachable)
    isAgentInstalled = installState.isAgentInstalled
    isAgentApprovalPending = installState.isApprovalPending
  }

  // MARK: - Routing control

  /// Whether an active config exists to relay through, the gate that decides a
  /// connected peer can route at all. The Mac reads the agent's active config id;
  /// the iPhone, whose tunnel carries its own config, mirrors its saved-tunnel flag.
  var hasActiveConfig: Bool {
    if usesEgressRoster {
      return activeConfigID != nil
    }
    return isTunnelInstalled
  }

  /// The derived state of the single Route traffic switch, computed once from the
  /// agent's shared routing intent so both screens render the switch the same way and
  /// the rule stays unit tested in `RouteControl`.
  var routeControl: RouteControl {
    RouteControl(
      isPeerConnected: connectedPeerName != nil,
      isRoutingEngaged: routingIntentEnabled,
      hasActiveConfig: hasActiveConfig,
      isRouting: routeState == .installed,
      requestedRouting: requestedRouting,
      isRequestPending: isRouteRequestPending
    )
  }

  /// The routing value the switch shows, read straight from the derived control. It
  /// reads on while a turn-on request is pending or the agent's routing intent is
  /// engaged, so the iPhone and the Mac show the same switch and a link blip does not
  /// flip it; the status word reports the live state separately.
  var displayedRouting: Bool {
    routeControl.isOn
  }

  /// Whether a routing request is awaiting the agent's confirmation, so the
  /// reconcile loop counts down and the derived control can report connecting.
  var isRouteRequestPending: Bool {
    routeIntentPollsRemaining > 0
  }

  func setRouteTraffic(enabled: Bool) async {
    logger.notice(
      "relay controller route traffic requested enabled=\(enabled, privacy: .public)")
    requestedRouting = enabled
    routeIntentPollsRemaining = enabled ? routeConnectTimeoutPolls : routeIntentTimeoutPolls
    await backend.setRouting(enabled: enabled)
  }

  // Clears the optimistic pending request once the agent's routing intent confirms the
  // request, or after the poll budget elapses, so the switch follows the confirmed
  // value and a request the agent never applies snaps back rather than spinning
  // forever.
  private func reconcileRouteIntent() {
    guard isRouteRequestPending else {
      return
    }
    if routingIntentEnabled == requestedRouting {
      routeIntentPollsRemaining = 0
      return
    }
    routeIntentPollsRemaining -= 1
    if routeIntentPollsRemaining <= 0 {
      logger.notice(
        "relay controller route request unconfirmed; reverting switch to real state")
    }
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

  // MARK: - Config library

  // The library list and active id are published properties mirrored from the
  // status poll (`configLibrary`, `activeConfigID`), so the card reads the same
  // source as the Relay tile. Mutations go to the backend and the next poll
  // reflects them.

  /// Loads a stored config's secret text on demand, for the editor only.
  func loadConfigText(id: UUID) async -> String? {
    logger.notice("relay controller load config text requested")
    return await backend.loadConfigText(id: id)
  }

  /// Imports a picked configuration file, then validates, stores, and applies it.
  func importConfig(url: URL, name: String) {
    logger.notice("relay controller import config requested")
    Task { await backend.importConfig(url: url, name: name) }
  }

  /// Makes a stored configuration active and applies it.
  func activateConfig(id: UUID) {
    logger.notice("relay controller activate config requested")
    Task { await backend.activateConfig(id: id) }
  }

  /// Saves edited configuration text and reloads it when it is the active config.
  func saveConfigEdit(id: UUID, text: String) {
    logger.notice("relay controller save config edit requested")
    Task { await backend.saveConfigEdit(id: id, text: text) }
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

// MARK: - Peer selection

extension RelayController {
  /// Whether available peers come from the dialed-in roster, true on the Mac, so the
  /// status word reflects connected iPhones rather than Bonjour discovery.
  var usesEgressRoster: Bool {
    backend.usesEgressRoster
  }

  /// Selects which dialed-in iPhone the Mac routes egress through. The next status
  /// snapshot reflects the new selection in the roster.
  func selectEgressPeer(id: String) async {
    logger.notice("relay controller select egress peer id=\(id, privacy: .public)")
    await backend.selectEgressPeer(id: id)
  }

  // Auto-dials the first discovered peer when the backend opts in (the iPhone) and
  // none is selected, so the iPhone connects to its Mac with no picker. The guard
  // clears once the request returns, and the next snapshot's selected id stops it
  // from firing again.
  func maybeAutoSelectPeer() {
    guard backend.autoSelectsDiscoveredPeer, !autoSelectInFlight, selectedPeerID == nil,
      let first = discoveredPeers.first
    else {
      return
    }
    autoSelectInFlight = true
    logger.notice("relay controller auto-dialing discovered peer")
    Task { @MainActor [weak self] in
      await self?.backend.selectPeer(id: first.id)
      self?.autoSelectInFlight = false
    }
  }
}

// MARK: - Config operations

extension RelayController {
  /// Deletes a stored configuration.
  func deleteConfig(id: UUID) {
    logger.notice("relay controller delete config requested")
    Task { await backend.deleteConfig(id: id) }
  }
}

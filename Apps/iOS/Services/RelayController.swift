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
  /// The bytes the Mac has sent and received through the relay, in the directions a
  /// person reads them. The relay's two ends count opposite directions under the
  /// same names: the Mac counts bytes arriving from the WireGuard server as its
  /// download, while the iPhone counts bytes it forwards to the Mac as the Mac's
  /// download. Resolving that here, where the producer is known, lets the speed and
  /// lifetime figures share one mapping on both platforms.
  var uploadBytes: UInt64
  var downloadBytes: UInt64
  /// The saved VPN profile as the producer found it, or nil when it could not be
  /// read or the producer does not report it. Nil is deliberately not the same as
  /// enabled: a read that failed says nothing about the profile, so the screen keeps
  /// what it last knew rather than flipping away from the re-enable state.
  var vpnProfileState: TunnelVPNProfileState?

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
    if let phoneCounters = snapshot.phoneCounters {
      // The iPhone forwards for the Mac, so bytes it receives from the Mac are the
      // Mac's upload and bytes it sends to the Mac are the Mac's download.
      uploadBytes = phoneCounters.relayBytesIn
      downloadBytes = phoneCounters.relayBytesOut
    } else {
      // The Mac counts its own traffic, so bytes leaving for the server are upload
      // and bytes arriving from it are download.
      let macCounters = snapshot.macCounters ?? TunnelCounters()
      uploadBytes = macCounters.relayBytesOut
      downloadBytes = macCounters.relayBytesIn
    }
    vpnProfileState = snapshot.vpnProfileState
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

  #if targetEnvironment(macCatalyst)
    let configLibraryBackend: any ConfigLibraryBackend
    let installState: InstallationState
  #else
    private let phoneProvisioningBackend: any PhoneTunnelProvisioningBackend
  #endif

  private let deviceProbe: DeviceEgressProbe?
  /// The one task reading status, whichever way the backend supplies it: reading a
  /// stream the source sends, or asking a source that has to be asked.
  private var statusTask: Task<Void, Never>?
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

  #if targetEnvironment(macCatalyst)
    /// The active config id held across a new-config create and restore so the poll
    /// cannot momentarily surface the agent's intermediate "new config is active" state
    /// between `importConfig` and the restoring `activateConfig`. Non-nil only while a
    /// create that preserves a prior active config is in flight.
    var pinnedActiveConfigID: UUID?
    /// Whether the background agent is installed, the gate to the install-agent setup
    /// tier on Mac Catalyst.
    var isAgentInstalled = true
  #endif

  /// Whether a tunnel profile is saved, the gate to the install-tunnel setup tier.
  var isTunnelInstalled = false

  /// Whether the saved VPN profile is switched off, the gate to the re-enable setup
  /// tier. Routing cannot start until the user turns the profile back on, so the
  /// screen offers that rather than the routing switch.
  var isVPNProfileDisabled = false

  #if targetEnvironment(macCatalyst)
    /// Whether the agent install is registered but awaiting the user's Login Items
    /// approval, surfaced so the setup screen can route them to System Settings.
    var isAgentApprovalPending = false
  #endif

  /// The peers discovery currently sees, the selected peer's id, and the discovery
  /// phase, the inputs to the peers list and the no-peer states.
  var discoveredPeers: [TunnelRelayService] = []
  var selectedPeerID: String?
  var discoveryPhase: TunnelDiscoveryPhase = .stopped
  /// The iPhones currently dialed into the Mac agent, the roster the Mac selector
  /// lists. Empty on the iPhone, which hosts no roster.
  var connectedPeers: [ConnectedPeer] = []
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

  #if targetEnvironment(macCatalyst)
    /// The agent's config library mirrored from the status poll, the rows the Configs
    /// card lists, so the card reads the same source as the Relay tile and the two
    /// never diverge.
    var configLibrary: [TunnelConfigSummary] = []
    /// The active config's id, mirrored from the same poll, the entry the card marks
    /// active and the running tunnel uses.
    var activeConfigID: UUID?

    init(
      backend: some RelayControlBackend & ConfigLibraryBackend,
      throughput: ThroughputCalculator,
      lifetimeStore: LifetimeDataStore,
      installState: InstallationState = InstallationState(),
      deviceProbe: DeviceEgressProbe? = nil
    ) {
      self.backend = backend
      configLibraryBackend = backend
      self.throughput = throughput
      self.lifetimeStore = lifetimeStore
      self.installState = installState
      self.deviceProbe = deviceProbe
    }
  #else
    init(
      backend: some RelayControlBackend & PhoneTunnelProvisioningBackend,
      throughput: ThroughputCalculator,
      lifetimeStore: LifetimeDataStore,
      deviceProbe: DeviceEgressProbe? = nil
    ) {
      self.backend = backend
      phoneProvisioningBackend = backend
      self.throughput = throughput
      self.lifetimeStore = lifetimeStore
      self.deviceProbe = deviceProbe
    }
  #endif

  // MARK: - Lifecycle

  /// Brings the platform session up, starts the app's own egress probe, then starts
  /// the status poll.
  func start() async {
    logger.notice("relay controller start requested")
    startDeviceProbe()
    await backend.start()
    startStatusUpdates()
  }

  /// Starts the relay only when the platform's own required setup is complete.
  func prepare() async {
    logger.notice("relay controller prepare requested")
    #if targetEnvironment(macCatalyst)
      await start()
    #else
      let provisioned = await phoneProvisioningBackend.tunnelProvisioned()
      if provisioned {
        await start()
      } else {
        isTunnelInstalled = false
        logger.notice("relay controller prepare found no saved tunnel")
      }
    #endif
  }

  /// Refreshes saved tunnel presence and starts the relay when provisioned and idle.
  func refreshProvisioned() async {
    logger.notice("relay controller provisioned refresh requested")
    #if targetEnvironment(macCatalyst)
      if statusTask == nil {
        await start()
      }
    #else
      let provisioned = await phoneProvisioningBackend.tunnelProvisioned()
      if !provisioned {
        isTunnelInstalled = false
        logger.notice("relay controller provisioned refresh found no saved tunnel")
        return
      }
      if statusTask == nil {
        await start()
      }
    #endif
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

  /// Stops reading status without touching the session, for backgrounding. Where the
  /// source sends readings, this ends the subscription, so it stops sending to a screen
  /// nobody is looking at.
  func suspendPolling() {
    logger.notice("relay controller suspending status updates")
    stopStatusUpdates()
  }

  /// Resumes reading status after the app comes back to the front.
  func resumePolling() {
    logger.notice("relay controller resuming status updates")
    startStatusUpdates()
  }

  // MARK: - Status updates

  private func startStatusUpdates() {
    statusTask?.cancel()
    throughput.reset()
    logger.notice("relay controller status updates starting")
    statusTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else {
          return
        }
        await readStatusRound()
        guard !Task.isCancelled else {
          return
        }
        await Self.delayBetweenPolls()
      }
    }
  }

  /// One round is either the whole life of a subscription or a single reading, whichever
  /// the backend offers.
  ///
  /// A subscription that finishes means the source went away, so the loop waits and
  /// opens another rather than giving up. That retry is what brings the screen back by
  /// itself once the source returns.
  private func readStatusRound() async {
    if let updates = backend.statusUpdates() {
      for await sample in updates {
        apply(sample)
        #if targetEnvironment(macCatalyst)
          await refreshInstallState(agentReachable: true)
        #endif
      }
      logger.notice("relay controller status stream ended")
      #if targetEnvironment(macCatalyst)
        await refreshInstallState(agentReachable: false)
      #endif
      return
    }
    if let sample = await backend.sample() {
      apply(sample)
      #if targetEnvironment(macCatalyst)
        await refreshInstallState(agentReachable: true)
      #endif
    } else {
      #if targetEnvironment(macCatalyst)
        await refreshInstallState(agentReachable: false)
      #endif
    }
  }

  private func stopStatusUpdates() {
    logger.notice("relay controller status updates stopping")
    statusTask?.cancel()
    statusTask = nil
  }

  private func apply(_ sample: RelayStatusSample) {
    assign(\.isRunning, sample.isRunning)
    assign(\.connectedPeerName, sample.connectedPeerName)
    assign(\.backendCellularPath, sample.cellularPath)
    assign(\.counters, sample.counters)
    let lifetime = lifetimeStore.totals(
      sessionTransferred: sample.uploadBytes,
      sessionReceived: sample.downloadBytes
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
    // Only a state the producer actually read replaces what the screen knows, so one
    // failed read cannot swap the re-enable screen for a routing switch that would not
    // work.
    if let vpnProfileState = sample.vpnProfileState {
      assign(\.isVPNProfileDisabled, vpnProfileState == .disabled)
    }
    assign(\.discoveredPeers, sample.discoveredPeers)
    assign(\.selectedPeerID, sample.selectedPeerID)
    assign(\.discoveryPhase, sample.discoveryPhase)
    assign(\.connectedPeers, sample.connectedPeers)
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
    #if targetEnvironment(macCatalyst)
      assign(\.configLibrary, sample.configLibrary)
      // While a create-and-restore is in flight, `pinnedActiveConfigID` holds the prior
      // active id so a poll landing mid-sequence cannot flicker the checkmark onto the
      // new config; it is nil otherwise, so the snapshot's id wins.
      assign(\.activeConfigID, pinnedActiveConfigID ?? sample.activeConfigID)
    #endif
    recomputeDeviceValues()
    let rate = throughput.update(
      uploadBytes: sample.uploadBytes, downloadBytes: sample.downloadBytes)
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

  #if targetEnvironment(macCatalyst)
    // Refreshes the agent install state each poll, so the install-agent setup tier
    // appears on a Mac with no agent and clears once the agent answers or is enabled.
    // The install read runs off the main actor, so the poll awaits it and the main
    // thread stays free to present modals mid-poll.
    private func refreshInstallState(agentReachable: Bool) async {
      await installState.refresh(agentReachable: agentReachable)
      isAgentInstalled = installState.isAgentInstalled
      isAgentApprovalPending = installState.isApprovalPending
    }
  #endif

}

// MARK: - Routing control

extension RelayController {

  /// Whether the current platform has an active relay configuration. Mac Catalyst
  /// reads the agent library selection, while the iPhone reads its approved VPN state.
  var hasActiveConfig: Bool {
    #if targetEnvironment(macCatalyst)
      return activeConfigID != nil
    #else
      return isTunnelInstalled
    #endif
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

  /// Selects which dialed-in iPhone the Mac routes egress through. The roster is updated
  /// optimistically so the checkmark moves on the same frame as the tap; the next status
  /// snapshot reconciles the selection.
  func selectEgressPeer(id: String) async {
    logger.notice("relay controller select egress peer id=\(id, privacy: .public)")
    connectedPeers = connectedPeers.map { peer in
      var updated = peer
      updated.isSelected = peer.id == id
      return updated
    }
    await backend.selectEgressPeer(id: id)
  }

}

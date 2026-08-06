//
//  RelayStatusSample.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-02.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation

// MARK: - Constants

let relayStoppedStateText = "Stopped"

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
  /// Every address on the producer's egress interface. The app used to read these
  /// itself, once per poll, rather than take the producer's own reading.
  var deviceInterfaceAddresses: InterfaceAddressList
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
  /// Whether this Mac publishes the record an iPhone looks for, or nil from a producer
  /// that predates the field. A reader tells that apart from a Mac that is genuinely
  /// silent, which is the difference between waiting and never being found.
  var advertising: TunnelAdvertisingState?
  /// The totals the producer accumulated itself, or nil from one that keeps none. A
  /// producer that runs continuously sees every reading, and this app does not.
  var lifetimeBytes: LifetimeByteTotals?
  /// Where the producer says it is between the two settled routing states, or nil from a
  /// producer that does not say.
  var routingPhase: TunnelRoutingPhase?
  /// Which situation the producer says the machine is in, or nil from a producer that
  /// publishes none, which leaves the screen to derive it from the fields above.
  var situation: RelaySituation?

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
    deviceInterfaceAddresses = snapshot.deviceInterfaceAddresses ?? .empty
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
    advertising = snapshot.advertising
    lifetimeBytes = snapshot.lifetimeBytes
    routingPhase = snapshot.routingPhase
    situation = snapshot.situation
  }
}

//
//  AgentTunnelController.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-27.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
@preconcurrency import NetworkExtension
import Synchronization

// MARK: - AgentTunnelController

actor AgentTunnelController {
  // MARK: - Constants

  /// Provider and tunnel-manager constants the controller and its split-out extensions
  /// share, scoped to the type so they do not add module-level names.
  nonisolated static let providerBundleIdentifier = tunnelProviderBundleIdentifier
  nonisolated static let providerConfigWireGuardKey = "wireguardConfig"
  nonisolated static let providerConfigConfigIDKey = "configID"
  nonisolated static let providerConfigRelayServiceKey = "selectedRelayServiceName"
  nonisolated static let tunnelLocalizedDescription = "Cell Tunnel"
  nonisolated static let tunnelServerAddressPlaceholder = "iPhone Cellular Relay"
  nonisolated static let providerMessageTimeoutSeconds: Double = 5

  // MARK: - State

  /// The saved tunnel manager once resolved, the actor's own state read and written
  /// only through `currentManager()`, `setManager(_:)`, and `clearManager()` so the
  /// split-out extensions do not touch the stored property directly.
  private var manager: NETunnelProviderManager?
  /// The VPN status observer token, owned here and replaced only through
  /// `replaceStatusObserver(_:)` so the lifecycle stays in one place.
  private var statusObserver: NSObjectProtocol?
  var controlListener: AgentControlListener?
  let relayBridge: AgentRelayBridge
  let relayBrowser: RelayDeviceBrowser
  /// The agent's config library, the single source of truth the Mac app and the
  /// command-line tool both read over XPC. Every status response carries its
  /// text-free summaries, and the start path registers whatever config it runs.
  let configStore: TunnelConfigStore
  /// The loud message set by the boot assertion when the running tunnel's stamped
  /// config id disagrees with the library, or `nil` when they agree. Read into every
  /// status snapshot's `configDrift`. The assertion never mutates the library.
  var configDriftMessage: String?

  /// The carrying link info, written from the bridge's egress callback off-actor and
  /// read into the served snapshot. Nonisolated because the `Mutex` is its own
  /// synchronization and the bridge callback runs off the actor.
  nonisolated let linkInfo = Mutex(AgentLinkInfo())
  /// This Mac's relay-link candidates, the open phone links from the bridge,
  /// written off the actor and read into the served snapshot's
  /// `localAvailableLinks`.
  nonisolated let localLinks = Mutex<[RelayLinkSummary]>([])
  /// The candidates the iPhone reports about itself in its status pushes,
  /// read into the served snapshot's `peerAvailableLinks`. Cleared when the
  /// phone link drops.
  nonisolated let peerLinks = Mutex<[RelayLinkSummary]?>(nil)
  /// The full adopted-link set, written from the bridge's link-set callback off the
  /// actor and read into the served snapshot's `agentLinks`.
  nonisolated let agentLinks = Mutex<[AgentLinkStatus]>([])
  /// The connected iPhone's name, written from the listener's status handler off
  /// the actor and read into the served snapshot as `connectedPeerName`. Cleared
  /// when the phone link drops.
  nonisolated let peerName = Mutex<String?>(nil)
  /// The roster of iPhones currently holding a control connection, written from the
  /// listener's roster callback off the actor and read into the served snapshot's
  /// `connectedPeers`, the set the Mac selector lists. Cleared when the listener stops.
  nonisolated let connectedPeers = Mutex<[ConnectedPeer]>([])
  /// The Mac's latest egress reading, written from the egress monitor off the actor
  /// and mapped into the served snapshot's `cellularPath`, so the Mac `Device`
  /// section reports the Mac's own egress.
  nonisolated let egressPath = Mutex(EgressPath())
  /// The public-address exchange with the iPhone, read into the served snapshot.
  var publicExchange: PublicAddressExchange?
  /// Watches the Mac's own egress path so a Wi-Fi or interface change re-probes the
  /// public address.
  var egressMonitor: EgressPathMonitor?
  /// Re-probes the public address on a slow backstop while the listener is up, so a
  /// missed path event cannot leave the served address stale.
  var publicRefreshTimer: DispatchSourceTimer?
  /// One-shot timer that delays a route withdrawal after the phone link drops, so a
  /// brief data-link blip does not flip the UI to passthrough. Cancelled when the
  /// link returns within the grace window.
  var routeWithdrawTimer: DispatchSourceTimer?
  /// Bumped on every phone-link transition so a pending debounced withdrawal that
  /// is no longer current is ignored when its timer fires.
  var routeWithdrawGeneration = 0

  init(
    relayBridge: AgentRelayBridge,
    relayBrowser: RelayDeviceBrowser,
    configStore: TunnelConfigStore = AgentConfigStore()
  ) {
    self.relayBridge = relayBridge
    self.relayBrowser = relayBrowser
    self.configStore = configStore
  }

  /// Whether routing is on, which now equals "is the relay session active": turning
  /// routing on starts the relay session and turning it off tears it down. This is a
  /// live in-memory value with no persistence and no default, so it resets to off on
  /// agent start. The agent installs the program routes only while this is true and a
  /// phone link is up.
  var routingEnabled = false

  /// The message from a detached relay start that failed, surfaced into the status
  /// snapshot's `lastError` so the app reverts the Route traffic switch to off and
  /// shows the error rather than holding a stuck connecting state. Cleared on the
  /// next enable, on disable, and on a successful start.
  var lastStartError: String?

  /// Whether the relay bridge is actually hosted, set true once the selected peer is
  /// armed and the bridge is started and cleared when the relay stops. Enabling routing
  /// reconciles routes against this rather than the macOS VPN session, which can read
  /// connected after the agent and bridge are gone, so the switch never shows on while
  /// nothing is relayed.
  var relayHosted = false

  /// Bumped on every routing enable and disable so an in-flight detached relay start
  /// can tell that a later switch toggle superseded it.
  var routingGeneration = 0

  /// The in-flight detached relay start. The next start awaits it so two starts never
  /// run concurrently, and a superseded start bows out on the generation check.
  var relayStartTask: Task<Void, Never>?

  /// Whether a phone relay link is up, tracked from the relay bridge so a routing
  /// change installs or withdraws routes against the live link state.
  var phoneLinkUp = false

  /// Called when the relay goes active or inactive so the runtime can hold the
  /// agent idle timer while it hosts the relay bridge. Set once at startup.
  var onRelayActiveChange: (@Sendable (Bool) -> Void)?

  // MARK: - Relay activity hold

  func setRelayActiveHandler(_ handler: @escaping @Sendable (Bool) -> Void) {
    onRelayActiveChange = handler
  }

  // MARK: - Manager and observer access

  /// The resolved tunnel manager, or `nil` before the first resolve. The split-out
  /// extensions read the manager through this rather than the stored property.
  func currentManager() -> NETunnelProviderManager? {
    manager
  }

  /// Stores the resolved tunnel manager.
  func setManager(_ newManager: NETunnelProviderManager) {
    manager = newManager
  }

  /// Drops the resolved tunnel manager after a reset.
  func clearManager() {
    manager = nil
  }

  /// Replaces the VPN status observer, removing any prior one, so the observer
  /// lifecycle stays in one place rather than mutating the stored property cross-file.
  func replaceStatusObserver(_ token: NSObjectProtocol?) {
    if let statusObserver {
      NotificationCenter.default.removeObserver(statusObserver)
    }
    statusObserver = token
  }
}

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

/// How many times in a row a failed control listener is rebuilt before the agent
/// stops trying. A port held by another process fails every attempt, so an unbounded
/// loop would log and rebuild for the rest of the agent's life. A later client
/// request starts a fresh run.
private let controlListenerRestartMaxAttempts = 5

/// How long to wait before the first rebuild. A port held by a previous instance is
/// usually free within a second, so the first retry is quick.
private let controlListenerRestartBaseDelayMs = 500

/// The longest wait between rebuilds. Each attempt waits twice as long as the one
/// before, up to this, which keeps a condition that has not cleared from being asked
/// about constantly while still recovering within a time a person would wait.
private let controlListenerRestartMaxDelayMs = 8_000

/// Where the folded byte totals are kept between runs. These are the keys the app wrote,
/// so a Mac that carried traffic before this change keeps its history.
///
/// An earlier pair of keys is deliberately not read: one platform seeded it with the two
/// directions swapped, so inheriting it would report what was uploaded as what was
/// downloaded.
let lifetimeUploadBaseKey = "lifetimeRelayBytesUploadBase"
let lifetimeDownloadBaseKey = "lifetimeRelayBytesDownloadBase"

/// How often the totals fold with no client connected. Slow, because it exists only so
/// traffic carried while nobody is looking still reaches the total.
let lifetimeAccrualIntervalSeconds = 10

/// The totals as the last run left them, or empty ones on a Mac that has carried nothing.
///
/// Only the folded bases are stored. The live session reading is re-read from the relay's
/// own counters, so a stored copy of it could never disagree with them.
func storedLifetimeByteTotals() -> LifetimeByteTotals {
  guard let defaults = UserDefaults(suiteName: cellTunnelAppGroupIdentifier) else {
    return LifetimeByteTotals()
  }
  return LifetimeByteTotals(
    uploadBase: UInt64(defaults.string(forKey: lifetimeUploadBaseKey) ?? "") ?? 0,
    downloadBase: UInt64(defaults.string(forKey: lifetimeDownloadBaseKey) ?? "") ?? 0
  )
}

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
  /// The in-flight control-listener start, so concurrent callers share one listener.
  /// This actor is re-entrant, so a nil check followed by an await is not enough on its
  /// own to keep a second caller from starting a second listener on the same port.
  var controlListenerStart: Task<Void, Error>?
  /// How long to wait before rebuilding a control listener that failed, and when to
  /// stop rebuilding. A listener that binds clears the run of failures.
  var listenerRestart = ListenerRestartPolicy(
    maxAttempts: controlListenerRestartMaxAttempts,
    baseDelayMilliseconds: controlListenerRestartBaseDelayMs,
    maxDelayMilliseconds: controlListenerRestartMaxDelayMs
  )
  /// The pending rebuild of a failed control listener, cancelled by a teardown.
  var listenerRestartTimer: DispatchSourceTimer?
  /// Which control listener the controller is currently willing to hear from. It is
  /// bumped whenever a listener is retired, so a report or a rebuild belonging to an
  /// older one is ignored rather than tearing down its replacement.
  var controlListenerGeneration = 0
  /// Whether a rebuild is currently building a listener, read as that listener is
  /// stored so a later report knows where it came from.
  var isRebuildingControlListener = false
  /// Whether the listener currently held came from a rebuild rather than from a
  /// client request. A rebuilt listener that binds does not clear the run of
  /// failures, so a listener that binds and fails repeatedly still reaches the bound.
  var controlListenerFromRebuild = false
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
  /// The last profile state a read actually returned, so the published situation holds
  /// steady across a read that failed and said nothing.
  var lastKnownProfileState: TunnelVPNProfileState?

  /// The clients listening for status pushes, shared with the session listener so the
  /// side that knows the state and the side that knows the connections work from one
  /// list.
  nonisolated let subscribers: SubscriberRegistry
  /// The repeating push that carries the byte counters while a relay is hosted, or nil
  /// while nothing is listening.
  var statusPushTimer: DispatchSourceTimer?

  /// The bytes moved over this Mac's whole life.
  ///
  /// The daemon owns this because it is the only party that sees every reading. An app
  /// that held it counted only what moved while it was open, so traffic carried with the
  /// window closed never reached the total. Behind a lock because the accrual timer and a
  /// client's status call both reach it.
  nonisolated let lifetimeBytes = Mutex(storedLifetimeByteTotals())
  /// The slow fold that keeps the totals advancing with no client connected.
  var lifetimeAccrualTimer: DispatchSourceTimer?

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
    configStore: TunnelConfigStore = AgentConfigStore(),
    subscribers: SubscriberRegistry = SubscriberRegistry()
  ) {
    self.relayBridge = relayBridge
    self.relayBrowser = relayBrowser
    self.configStore = configStore
    self.subscribers = subscribers
  }

  /// The desired routing intent, not a guarantee that the relay session is active.
  /// Turning routing on sets this true and starts the relay session; turning it off
  /// clears it and tears the session down. It is set true before the detached start
  /// completes, so it can be true while the session is still connecting; `relayHosted`
  /// tracks whether the bridge is actually up. A live in-memory value with no persistence
  /// and no default, so it resets to off on agent start. The agent installs the program
  /// routes only while this is true and a phone link is up.
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
  /// The routing generation of the start that is between requested and settled, or nil
  /// when none is. The saved profile can report itself unavailable partway through a
  /// start, before the system has finished enabling it, so the observer that drops the
  /// routing intent stands down while this is set rather than cancelling the start the
  /// user just asked for. It records the generation rather than a plain flag so that an
  /// on, off, on sequence cannot have the first start's cleanup clear the claim staked
  /// by the third.
  var settlingStartGeneration: Int?

  /// Whether a phone relay link is up, tracked from the relay bridge so a routing
  /// change installs or withdraws routes against the live link state.
  var phoneLinkUp = false

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

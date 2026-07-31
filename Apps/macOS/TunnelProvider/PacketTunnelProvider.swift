//
//  PacketTunnelProvider.swift
//  CellTunnelTunnelProvider
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-27.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import Foundation
import Network
import NetworkExtension
import Synchronization
import WireGuardKit

private let logger = CellTunnelLog.logger(category: .daemon)

private let providerConfigWireGuardKey = "wireguardConfig"

// The relay protocol name surfaced on the status `Protocol` row. This provider is a
// WireGuard provider, so it is one of the few producers that names the protocol.
private let relayProtocolName = "WireGuard"

// The Mac tunnel extension reaches the relay data plane by dialing the agent on
// the loopback interface. The agent hosts the relay listener and bridges to the
// iPhone, because a listener inside this extension cannot receive inbound.
private let agentLoopbackHost = "127.0.0.1"

// The extension keepalives the agent over loopback and treats a run of
// unanswered keepalives as the agent being gone. Loopback does not lose
// datagrams, so a miss means the agent is not servicing its socket; three of them
// at two seconds tolerates a briefly stalled agent while keeping the window in
// which traffic is black holed to a few seconds.
private let relayKeepaliveIntervalMilliseconds = 2_000
private let relayMissedKeepalivesBeforeGone = 3

// The completion handler arrives from Objective-C without a Sendable marking;
// box it so the start Task can call it across the concurrency boundary.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
  let value: Value

  init(_ value: Value) {
    self.value = value
  }
}

// MARK: - PacketTunnelProviderError

enum PacketTunnelProviderError: LocalizedError {
  case missingWireGuardConfig

  var errorDescription: String? {
    switch self {
    case .missingWireGuardConfig:
      return "providerConfiguration is missing \(providerConfigWireGuardKey)"
    }
  }
}

// NEPacketTunnelProvider serializes the tunnel lifecycle callbacks, so the
// stored state mutated across start and stop is never touched concurrently.
// MARK: - PacketTunnelProvider

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
  private let relayMetrics: RelayMetrics
  private let relayTransport: RelayTransport
  private let wireGuardRuntime: WireGuardRuntime
  private let routeGate: RouteGate
  private var wireGuardRelayBind: WireGuardRelayBind?
  // The WireGuard server endpoint from the active config, reported as the relay's
  // public address so the Mac status shows the same endpoint the iPhone does.
  // The WireGuard server endpoint from the active config. Setting it resolves the
  // host once and caches the server's A and AAAA records, so the status path
  // reports the resolved addresses without a blocking lookup. An IP literal
  // resolves to itself.
  private var serverEndpoint: WireGuardEndpoint? {
    didSet {
      resolvedServerAddresses = serverEndpoint.map { endpoint in
        HostAddressResolver.resolve(host: endpoint.host)
      }
    }
  }
  private var resolvedServerAddresses: HostAddressResolver.Resolved?
  private var throughputLogger: RelayThroughputLogger?
  private var livenessMonitor: RelayLivenessMonitor?

  // The designated initializer takes the graph, so a test can build the provider
  // with fakes.
  init(
    relayMetrics: RelayMetrics,
    relayTransport: RelayTransport,
    wireGuardRuntime: WireGuardRuntime,
    routeGate: RouteGate
  ) {
    self.relayMetrics = relayMetrics
    self.relayTransport = relayTransport
    self.wireGuardRuntime = wireGuardRuntime
    self.routeGate = routeGate
    super.init()
    logger.notice("PacketTunnelProvider initialized")
  }

  // The system instantiates the provider through the no-argument initializer, so
  // this is the composition root: it builds the production graph, wiring the
  // relay transport to the shared metrics, and hands it to the designated init.
  override convenience init() {
    let metrics = RelayMetrics()
    self.init(
      relayMetrics: metrics,
      relayTransport: RelayTransport(metrics: metrics),
      wireGuardRuntime: WireGuardRuntime(),
      routeGate: RouteGate()
    )
  }

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    let optionCount = options?.count ?? 0
    let handlerBox = UncheckedSendableBox(completionHandler)
    Task {
      do {
        try await runStartTunnel(optionCount: optionCount)
        handlerBox.value(nil)
      } catch {
        logger.error(
          "tunnel start failed error=\(String(describing: error), privacy: .public) recovery=propagate-to-NE"
        )
        handlerBox.value(error)
      }
    }
  }

  private func runStartTunnel(optionCount: Int) async throws {
    logger.notice(
      "tunnel start request received optionsCount=\(optionCount, privacy: .public)"
    )

    let configText = try extractWireGuardConfigText()
    let parsedConfig = try WireGuardConfigParser.parse(configText)
    serverEndpoint = parsedConfig.peer.endpoint

    // Seed the captured route set from the config's AllowedIPs before
    // WireGuard applies settings, so the gate installs the scoped routes and
    // never the wide routes WireGuard derives from the broad cryptokey
    // allowed IPs.
    let programRoutes = ProgramRouteSet.routes(from: parsedConfig.peer.allowedIPs)
    _ = routeGate.setProgramRoutes(ipv4: programRoutes.ipv4, ipv6: programRoutes.ipv6)

    // Seed the config's DNS the same way, so the gate publishes it as the system
    // resolver while the link is up and withdraws it when the link drops.
    _ = routeGate.setProgramDNS(
      servers: parsedConfig.interface.dnsServers,
      searchDomains: parsedConfig.interface.dnsSearchDomains
    )

    let agentEndpoint = Self.agentRelayEndpoint()
    try relayTransport.connect(to: agentEndpoint)
    logger.notice(
      "relay transport connected to agent loopback host=\(agentLoopbackHost, privacy: .public)"
    )

    let relayBind = WireGuardRelayBind(transport: relayTransport, metrics: relayMetrics)
    wireGuardRelayBind = relayBind

    let tunnelConfiguration = try WireGuardTunnelConfigBuilder.build(
      from: parsedConfig,
      name: "CellTunnel"
    )
    try await wireGuardRuntime.start(
      tunnelConfiguration: tunnelConfiguration,
      relayBind: relayBind,
      provider: self
    )
    logger.notice("tunnel runtime started")

    let relayThroughputLogger = RelayThroughputLogger(metrics: relayMetrics)
    self.throughputLogger = relayThroughputLogger
    relayThroughputLogger.start()

    startLivenessMonitor()

    logger.notice("tunnel start completion handler called success=true")
  }

  override func stopTunnel(with reason: NEProviderStopReason) async {
    logger.notice(
      "tunnel stop request received reason=\(String(describing: reason), privacy: .public)"
    )
    stopLivenessMonitor()
    throughputLogger?.stop()
    throughputLogger = nil

    await wireGuardRuntime.stop()
    logger.notice("tunnel runtime stopped on shutdown")

    relayTransport.disconnect()
    logger.notice("relay transport disconnected on shutdown")

    wireGuardRelayBind = nil
    logger.notice("tunnel stop completion handler called")
  }

  override func handleAppMessage(
    _ messageData: Data,
    completionHandler: ((Data?) -> Void)?
  ) {
    let handlerBox = UncheckedSendableBox(completionHandler)
    let request: ProviderControlRequest
    do {
      request = try JSONDecoder().decode(
        ProviderControlEnvelope.self,
        from: messageData
      ).request
    } catch {
      logger.error(
        """
        app message decode failed \
        details=\(String(describing: error), privacy: .public) \
        recovery=reply-failure
        """
      )
      handlerBox.value?(encodeResponse(failureMessage: "decode failed"))
      return
    }
    let response = handleProviderRequest(request)
    handlerBox.value?(encodeResponse(response))
  }

  private func handleProviderRequest(
    _ request: ProviderControlRequest
  ) -> ProviderControlResponse {
    switch request {
    case .status:
      return ProviderControlResponse(status: currentStatusSnapshot())
    case .reloadConfig(let text):
      return reloadConfig(text)
    case .setRouteState(let installed):
      applyRouteState(installed)
      return ProviderControlResponse(status: currentStatusSnapshot())
    case .setRoutingEnabled:
      // The agent owns the routing choice and translates it into setRouteState,
      // so the Mac extension never receives this request directly.
      return ProviderControlResponse(status: currentStatusSnapshot())
    case .selectPeer:
      // The agent owns relay discovery and selection, so the Mac extension never
      // receives this request directly.
      return ProviderControlResponse(status: currentStatusSnapshot())
    case .discoverySnapshot:
      // Discovery is owned by the agent; the extension holds no browser.
      return ProviderControlResponse(discovery: TunnelDiscoverySnapshot())
    }
  }

  // Applies an edited config to the running tunnel in place. It re-seeds the
  // captured route set and applies it immediately, then reconfigures WireGuard
  // with the new config, with no session restart and no VPN profile save. The
  // WireGuard update preserves the relay bind, so the relay keeps carrying
  // datagrams across the change.
  private func reloadConfig(_ text: String) -> ProviderControlResponse {
    do {
      let parsedConfig = try WireGuardConfigParser.parse(text)
      serverEndpoint = parsedConfig.peer.endpoint
      let programRoutes = ProgramRouteSet.routes(from: parsedConfig.peer.allowedIPs)
      _ = routeGate.setProgramRoutes(ipv4: programRoutes.ipv4, ipv6: programRoutes.ipv6)
      // Seed DNS too and apply once, so a live reload swaps routes and DNS in a
      // single gated settings apply.
      if let settings = routeGate.setProgramDNS(
        servers: parsedConfig.interface.dnsServers,
        searchDomains: parsedConfig.interface.dnsSearchDomains
      ) {
        super.setTunnelNetworkSettings(settings, completionHandler: nil)
      }
      // The parsed config is Sendable; the WireGuard configuration it builds
      // is not, so build it inside the task and hand it straight to the
      // runtime, keeping the non-Sendable value from crossing a concurrency
      // boundary.
      let runtime = wireGuardRuntime
      let configForUpdate = parsedConfig
      Task {
        do {
          let tunnelConfiguration = try WireGuardTunnelConfigBuilder.build(
            from: configForUpdate,
            name: "CellTunnel"
          )
          await runtime.update(tunnelConfiguration: tunnelConfiguration)
        } catch {
          logger.error(
            """
            tunnel config reload update failed \
            details=\(String(describing: error), privacy: .public) recovery=keep-running
            """
          )
        }
      }
      logger.notice("tunnel config reload applied")
      return ProviderControlResponse(status: currentStatusSnapshot())
    } catch {
      logger.error(
        """
        tunnel config reload failed \
        details=\(String(describing: error), privacy: .public) recovery=keep-running
        """
      )
      return ProviderControlResponse(
        failureMessage: "reload failed: \(error.localizedDescription)"
      )
    }
  }

  // The agent signals the iPhone link state. Routes install only while the link
  // is up and withdraw when it drops, so the Mac tunnel stays connected with no
  // captured traffic when the relay is unreachable.
  private func applyRouteState(_ installed: Bool) {
    guard let settings = routeGate.setInstalled(installed) else {
      logger.notice(
        "route state change with no recorded settings installed=\(installed, privacy: .public)"
      )
      return
    }
    super.setTunnelNetworkSettings(settings) { [weak self] error in
      if let error {
        logger.error(
          """
          route state apply failed installed=\(installed, privacy: .public) \
          error=\(error.localizedDescription, privacy: .public) recovery=keep-tunnel
          """
        )
        return
      }
      logger.notice("route state applied installed=\(installed, privacy: .public)")
      // On a fresh start the gate holds captured routes back until the iPhone link
      // is up, so the tunnel establishes with no captured routes and comes up
      // non-primary. On a multi-homed Mac this first apply of the default route
      // installs the route but does not re-elect the tunnel as the primary
      // default, so non-scoped traffic keeps egressing through a physical uplink.
      // Re-assert the settings once, through the recording override so the routes
      // stay gated, to make macOS promote the tunnel to primary the way the
      // in-place reload path does. Only when installing captured routes.
      if installed {
        self?.setTunnelNetworkSettings(settings, completionHandler: nil)
      }
    }
  }

  override func setTunnelNetworkSettings(
    _ tunnelNetworkSettings: NETunnelNetworkSettings?,
    completionHandler: ((Error?) -> Void)?
  ) {
    guard let packetSettings = tunnelNetworkSettings as? NEPacketTunnelNetworkSettings else {
      super.setTunnelNetworkSettings(
        tunnelNetworkSettings,
        completionHandler: completionHandler
      )
      return
    }
    let gated = routeGate.record(packetSettings)
    super.setTunnelNetworkSettings(gated, completionHandler: completionHandler)
  }

  private func currentStatusSnapshot() -> TunnelDaemonStatusSnapshot {
    let running = wireGuardRelayBind != nil
    let addresses = routeGate.recordedAddresses()
    return TunnelDaemonStatusSnapshot(
      running: running,
      routeState: routeGate.isInstalled ? .installed : .notInstalled,
      peerState: running ? .wireGuardConfigured : .notSelected,
      ipv4Address: addresses.ipv4,
      ipv6Address: addresses.ipv6,
      macCounters: relayMetrics.snapshot(),
      relayHost: serverEndpoint?.host,
      relayServerIPv4Address: resolvedServerAddresses?.ipv4,
      relayServerIPv6Address: resolvedServerAddresses?.ipv6,
      relayProtocol: relayProtocolName
    )
  }

  private func encodeResponse(_ response: ProviderControlResponse) -> Data? {
    do {
      return try JSONEncoder().encode(response)
    } catch {
      logger.error(
        """
        app message response encode failed \
        details=\(String(describing: error), privacy: .public) \
        recovery=reply-failure
        """
      )
      return encodeResponse(failureMessage: "encode failed")
    }
  }

  private func encodeResponse(failureMessage: String) -> Data? {
    do {
      return try JSONEncoder().encode(
        ProviderControlResponse(failureMessage: failureMessage)
      )
    } catch {
      logger.error(
        """
        app message failure encode failed \
        details=\(String(describing: error), privacy: .public) \
        recovery=reply-nil
        """
      )
      return nil
    }
  }

  private func extractWireGuardConfigText() throws -> String {
    guard let providerProtocol = protocolConfiguration as? NETunnelProviderProtocol else {
      throw PacketTunnelProviderError.missingWireGuardConfig
    }
    guard let providerConfiguration = providerProtocol.providerConfiguration else {
      throw PacketTunnelProviderError.missingWireGuardConfig
    }
    guard let configText = providerConfiguration[providerConfigWireGuardKey] as? String else {
      throw PacketTunnelProviderError.missingWireGuardConfig
    }
    return configText
  }

  // The relay transport dials the agent on the loopback interface; the agent
  // hosts the relay listener and bridges datagrams to the iPhone.
  private static func agentRelayEndpoint() -> NWEndpoint {
    NWEndpoint.hostPort(
      host: NWEndpoint.Host(agentLoopbackHost),
      port: resolvedRelayListenerPort()
    )
  }
}

// MARK: - Agent liveness

extension PacketTunnelProvider {
  /// Starts watching the agent, so the captured routes come down when it goes away.
  ///
  /// This extension outlives the agent and holds the routes, so an agent that
  /// crashed or was force quit would otherwise leave every captured packet pointed
  /// at a relay bridge that no longer exists.
  ///
  /// The withdrawal callback runs on the monitor's queue. `applyRouteState` reads no
  /// stored property of this class other than the lock-guarded route gate before it
  /// hands the settings to NetworkExtension, so calling it from there leaves the
  /// serialization of the lifecycle callbacks intact.
  func startLivenessMonitor() {
    let monitor = RelayLivenessMonitor(
      transport: relayTransport,
      missedRepliesBeforeGone: relayMissedKeepalivesBeforeGone,
      intervalMilliseconds: relayKeepaliveIntervalMilliseconds
    )
    monitor.onAgentGone = { [weak self] in
      self?.applyRouteState(false)
    }
    livenessMonitor = monitor
    monitor.start()
  }

  /// Stops watching the agent. A shutdown calls this before closing the transport,
  /// so a tick already in flight cannot redial the socket being closed.
  func stopLivenessMonitor() {
    livenessMonitor?.stop()
    livenessMonitor = nil
  }
}

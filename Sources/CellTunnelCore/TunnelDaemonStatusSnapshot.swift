//
//  TunnelDaemonStatusSnapshot.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026, all rights reserved.
//

import Foundation

public enum TunnelAddressFamily: String, Codable, Equatable, Sendable {
  case ipv4
  case ipv6
  case unspecified
}

// MARK: - TunnelRouteState

public enum TunnelRouteState: String, Codable, Equatable, Sendable {
  case installed
  case notInstalled = "not-installed"
}

// MARK: - TunnelPeerState

public enum TunnelPeerState: String, Codable, Equatable, Sendable {
  case notSelected = "not-selected"
  case relaySelected = "relay-selected"
  case wireGuardConfigured = "wireguard-configured"
}

// MARK: - TunnelDiscoveryPhase

public enum TunnelDiscoveryPhase: String, Codable, Equatable, Sendable {
  case browsing
  case failed
  case ready
  case stopped
}

// MARK: - TunnelControlErrorCode

public enum TunnelControlErrorCode: String, Codable, Equatable, Sendable {
  case `internal` = "internal"
  case discoveryUnavailable = "discoveryUnavailable"
  case invalidRelayEndpoint = "invalidRelayEndpoint"
  case missingWireGuardConfigPath = "missingWireGuardConfigPath"
  case relaySelectionRequired = "relaySelectionRequired"
  case relayServiceNotFound = "relayServiceNotFound"
  case runtimeStartFailure = "runtimeStartFailure"
  case unspecified = "unspecified"
}

// MARK: - TunnelRelayService

public struct TunnelRelayService: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var serviceName: String
  public var serviceType: String
  public var domain: String
  public var interfaceIndex: Int
  public var hostName: String
  public var endpoints: [TunnelRelayEndpoint]
  public var preferredEndpoint: TunnelRelayEndpoint?
  public var isSelected: Bool

  public init(
    id: String,
    serviceName: String,
    serviceType: String,
    domain: String,
    interfaceIndex: Int,
    hostName: String,
    endpoints: [TunnelRelayEndpoint],
    preferredEndpoint: TunnelRelayEndpoint?,
    isSelected: Bool
  ) {
    self.id = id
    self.serviceName = serviceName
    self.serviceType = serviceType
    self.domain = domain
    self.interfaceIndex = interfaceIndex
    self.hostName = hostName
    self.endpoints = endpoints
    self.preferredEndpoint = preferredEndpoint
    self.isSelected = isSelected
  }

  public var displayName: String {
    if let preferredEndpoint {
      return "\(serviceName) \(preferredEndpoint.socketAddress)"
    }
    return serviceName
  }
}

// MARK: - TunnelDiscoverySnapshot

public struct TunnelDiscoverySnapshot: Codable, Equatable, Sendable {
  public var phase: TunnelDiscoveryPhase
  public var services: [TunnelRelayService]
  public var selectedServiceID: String?
  public var selectedEndpoint: TunnelRelayEndpoint?
  public var lastError: String?

  public init(
    phase: TunnelDiscoveryPhase = .stopped,
    services: [TunnelRelayService] = [],
    selectedServiceID: String? = nil,
    selectedEndpoint: TunnelRelayEndpoint? = nil,
    lastError: String? = nil
  ) {
    self.phase = phase
    self.services = services
    self.selectedServiceID = selectedServiceID
    self.selectedEndpoint = selectedEndpoint
    self.lastError = lastError
  }

  public var renderedOutput: String {
    var lines = ["discovery=\(phase.rawValue)"]
    if let selectedServiceID, !selectedServiceID.isEmpty {
      lines.append("selected_service_id=\(selectedServiceID)")
    }
    if let selectedEndpoint {
      lines.append("selected_endpoint=\(selectedEndpoint.socketAddress)")
    }
    for service in services {
      lines.append("service=\(service.displayName)")
      lines.append("  id=\(service.id)")
    }
    if let lastError, !lastError.isEmpty {
      lines.append("last_error=\(lastError)")
    }
    return lines.joined(separator: "\n")
  }
}

// MARK: - TunnelStartSettings

public struct TunnelStartSettings: Codable, Equatable, Sendable {
  public var wireGuardConfigPath: String
  public var relayEndpoint: TunnelRelayEndpoint?

  public init(wireGuardConfigPath: String = "", relayEndpoint: TunnelRelayEndpoint? = nil) {
    self.wireGuardConfigPath = wireGuardConfigPath
    self.relayEndpoint = relayEndpoint
  }

  public var hasWireGuardConfigPath: Bool {
    !wireGuardConfigPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  public var hasLocalRelayEndpoint: Bool {
    relayEndpoint?.isConfigured == true
  }

  public var usesDaemonSelectedRelay: Bool {
    relayEndpoint == nil
  }

  public var isReadyToStart: Bool {
    hasWireGuardConfigPath
  }
}

// MARK: - TunnelDaemonStatusSnapshot

public struct TunnelDaemonStatusSnapshot: Codable, Equatable, Sendable {
  public var running: Bool
  public var routeState: TunnelRouteState
  public var peerState: TunnelPeerState
  public var ipv4Address: String
  public var ipv6Address: String
  public var lastError: String?
  public var discovery: TunnelDiscoverySnapshot
  public var activeRelayEndpoint: TunnelRelayEndpoint?
  public var macCounters: TunnelCounters?
  public var phoneCounters: TunnelCounters?
  public var cellularPath: CellularPathSnapshot?
  public var connectedPeerName: String?
  public var relayState: String?
  /// The carrying link's raw interface identifier, shown beside its transport
  /// class on the `Connected via` row, or `nil` when no link is up.
  public var localLinkInterfaceName: String?
  /// The carrying link's transport class, the source of the `Connected via`
  /// transport word, or `nil` when no link is up.
  public var localLinkClass: RelayLinkClass?
  /// This host's effective public address, measured by its own probe, shown under
  /// `Device / Public`, or `nil` before the probe answers.
  public var devicePublicAddresses: AddressPair?
  /// The peer's effective public address, received over the control link, shown
  /// under `Peer / Public`, or `nil` before the peer reports it.
  public var peerPublicAddresses: AddressPair?
  /// The carrying interface's own addresses on this host, shown under
  /// `Connection / Local link`, or `nil` when no link is up.
  public var localLinkAddresses: AddressPair?
  /// The peer's address on the carrying link, the connection's remote endpoint,
  /// shown under `Connection / Peer link`, or `nil` when no link is up.
  public var peerLinkAddresses: AddressPair?
  /// The relay-link candidates on this side, the interfaces over which this
  /// host can reach or is reached by the peer, shown on the local `Available
  /// Interfaces` row, or `nil` when the producer has not reported them.
  public var localAvailableLinks: [RelayLinkSummary]?
  /// The relay-link candidates the peer reports about itself over the control
  /// link, shown on the peer `Available Interfaces` row, or `nil` before the
  /// peer reports them.
  public var peerAvailableLinks: [RelayLinkSummary]?
  /// The configured WireGuard endpoint hostname, shown as the relay host, or
  /// `nil` when not yet surfaced.
  public var relayHost: String?
  /// The WireGuard server's IPv4 address, the endpoint hostname resolved to its A
  /// record, or `nil` when not yet resolved.
  public var relayServerIPv4Address: String?
  /// The WireGuard server's IPv6 address, the endpoint hostname resolved to its
  /// AAAA record, or `nil` when not yet resolved.
  public var relayServerIPv6Address: String?
  /// The relay tunnel protocol name, shown as the status `Protocol` qualifier, set
  /// only by the WireGuard providers that build the snapshot, or `nil` elsewhere so
  /// the status surface reads the producer's value rather than a hardcoded literal.
  public var relayProtocol: String?
  /// The user's routing intent as the agent holds it, the value behind the Route
  /// traffic switch. Separate from `routeState`, which reports the routes actually
  /// installed. `nil` from a producer that predates the field.
  public var routingIntentEnabled: TunnelRoutingIntent?
  /// Every relay link the agent's bridge currently holds, carrying and warm, so
  /// one status call shows the whole link set. `nil` from a producer that
  /// predates the field.
  public var agentLinks: [AgentLinkStatus]?
  /// Every iPhone currently holding a control connection to the agent, the roster
  /// the Mac lists and selects egress through, with the selected one flagged. `nil`
  /// from a producer that predates the field; only the Mac agent populates it.
  public var connectedPeers: [ConnectedPeer]?
  /// The agent's whole config library as text-free summaries, so the Mac Configs
  /// card reads the same poll as the Relay tile and the two never diverge. `nil`
  /// from a producer that has no library (iPhone, simulator, preview).
  public var configLibrary: [TunnelConfigSummary]?
  /// The id of the active config in `configLibrary`, the one the running tunnel
  /// uses. `nil` when no config is active or the producer has no library.
  public var activeConfigID: String?

  public init(
    running: Bool = false,
    routeState: TunnelRouteState = .notInstalled,
    peerState: TunnelPeerState = .notSelected,
    ipv4Address: String = "",
    ipv6Address: String = "",
    lastError: String? = nil,
    discovery: TunnelDiscoverySnapshot = TunnelDiscoverySnapshot(),
    activeRelayEndpoint: TunnelRelayEndpoint? = nil,
    macCounters: TunnelCounters? = nil,
    phoneCounters: TunnelCounters? = nil,
    cellularPath: CellularPathSnapshot? = nil,
    connectedPeerName: String? = nil,
    relayState: String? = nil,
    localLinkInterfaceName: String? = nil,
    localLinkClass: RelayLinkClass? = nil,
    devicePublicAddresses: AddressPair? = nil,
    peerPublicAddresses: AddressPair? = nil,
    localLinkAddresses: AddressPair? = nil,
    peerLinkAddresses: AddressPair? = nil,
    localAvailableLinks: [RelayLinkSummary]? = nil,
    peerAvailableLinks: [RelayLinkSummary]? = nil,
    relayHost: String? = nil,
    relayServerIPv4Address: String? = nil,
    relayServerIPv6Address: String? = nil,
    relayProtocol: String? = nil,
    routingIntentEnabled: TunnelRoutingIntent? = nil,
    agentLinks: [AgentLinkStatus]? = nil,
    connectedPeers: [ConnectedPeer]? = nil,
    configLibrary: [TunnelConfigSummary]? = nil,
    activeConfigID: String? = nil
  ) {
    self.running = running
    self.routeState = routeState
    self.peerState = peerState
    self.ipv4Address = ipv4Address
    self.ipv6Address = ipv6Address
    self.lastError = lastError
    self.discovery = discovery
    self.activeRelayEndpoint = activeRelayEndpoint
    self.macCounters = macCounters
    self.phoneCounters = phoneCounters
    self.cellularPath = cellularPath
    self.connectedPeerName = connectedPeerName
    self.relayState = relayState
    self.localLinkInterfaceName = localLinkInterfaceName
    self.localLinkClass = localLinkClass
    self.devicePublicAddresses = devicePublicAddresses
    self.peerPublicAddresses = peerPublicAddresses
    self.localLinkAddresses = localLinkAddresses
    self.peerLinkAddresses = peerLinkAddresses
    self.localAvailableLinks = localAvailableLinks
    self.peerAvailableLinks = peerAvailableLinks
    self.relayHost = relayHost
    self.relayServerIPv4Address = relayServerIPv4Address
    self.relayServerIPv6Address = relayServerIPv6Address
    self.relayProtocol = relayProtocol
    self.routingIntentEnabled = routingIntentEnabled
    self.agentLinks = agentLinks
    self.connectedPeers = connectedPeers
    self.configLibrary = configLibrary
    self.activeConfigID = activeConfigID
  }

  public var renderedOutput: String {
    var lines = [
      "running=\(running)",
      "routes=\(routeState.rawValue)",
      "peer=\(peerState.rawValue)",
      "ipv4=\(ipv4Address)",
      "ipv6=\(ipv6Address)",
    ]
    if let routingIntentEnabled {
      lines.append("routing_intent=\(routingIntentEnabled.rawValue)")
    }
    if let agentLinks {
      lines.append("links=\(agentLinks.count)")
      for link in agentLinks {
        lines.append(
          "link.\(link.interfaceName)=\(link.linkClass.rawValue)"
            + (link.isCarrying ? " carrying" : " warm")
        )
      }
    }
    if let connectedPeers {
      lines.append("peers=\(connectedPeers.count)")
      for peer in connectedPeers {
        lines.append(
          "peer.\(peer.id)=\(peer.name)" + (peer.isSelected ? " selected" : "")
        )
      }
    }
    if let configLibrary {
      lines.append("configs=\(configLibrary.count)")
      for config in configLibrary {
        let activeMark = config.id == activeConfigID ? " active" : ""
        lines.append("config.\(config.id)=\(config.name)\(activeMark)")
      }
    }
    if let activeRelayEndpoint {
      lines.append("relay=\(activeRelayEndpoint.socketAddress)")
    }
    if let macCounters {
      lines.append(contentsOf: renderedCounterLines(macCounters, prefix: "mac"))
    }
    if let phoneCounters {
      lines.append(contentsOf: renderedCounterLines(phoneCounters, prefix: "phone"))
    }
    if let lastError, !lastError.isEmpty {
      lines.append("last_error=\(lastError)")
    }
    return lines.joined(separator: "\n")
  }

  private func renderedCounterLines(
    _ counters: TunnelCounters,
    prefix: String
  ) -> [String] {
    [
      "\(prefix)_datagrams_from_mac=\(counters.wireGuardDatagramsFromMac)",
      "\(prefix)_datagrams_to_mac=\(counters.wireGuardDatagramsToMac)",
      "\(prefix)_datagrams_to_server=\(counters.wireGuardDatagramsToServer)",
      "\(prefix)_datagrams_from_server=\(counters.wireGuardDatagramsFromServer)",
      "\(prefix)_dropped=\(counters.droppedWireGuardDatagrams)",
      "\(prefix)_bytes_in=\(counters.relayBytesIn)",
      "\(prefix)_bytes_out=\(counters.relayBytesOut)",
    ]
  }
}

// MARK: - TunnelControlFailure

public struct TunnelControlFailure: Sendable {
  public var errorCode: TunnelControlErrorCode
  public var message: String

  public init(errorCode: TunnelControlErrorCode, message: String) {
    self.errorCode = errorCode
    self.message = message
  }
}

// MARK: - TunnelRPCFailure

public struct TunnelRPCFailure: Sendable {
  public var code: String
  public var message: String
  public var cause: String?

  public init(code: String, message: String, cause: String?) {
    self.code = code
    self.message = message
    self.cause = cause
  }
}

// MARK: - TunnelDaemonError

public enum TunnelDaemonError: LocalizedError, Sendable {
  case controlFailure(TunnelControlFailure)
  case daemonUnavailable(String)
  case rpcFailure(TunnelRPCFailure)
  case transportFailure(String)
  case usage(String)

  public var errorDescription: String? {
    switch self {
    case .controlFailure(let failure):
      return failure.message
    case .daemonUnavailable(let endpoint):
      return "CellTunnelAgent is not running at \(endpoint)"
    case .rpcFailure(let failure):
      if let cause = failure.cause {
        if !cause.isEmpty {
          return "rpc code=\(failure.code) message=\(failure.message) cause=\(cause)"
        }
      }
      return "rpc code=\(failure.code) message=\(failure.message)"
    case .transportFailure(let message):
      return message
    case .usage(let message):
      return message
    }
  }

  public var renderedOutput: String {
    switch self {
    case .controlFailure(let failure):
      return [
        "error_kind=control",
        "error_code=\(failure.errorCode.rawValue)",
        "message=\(failure.message)",
      ].joined(separator: "\n")
    case .daemonUnavailable(let socketPath):
      return [
        "error_kind=daemon_unavailable",
        "socket_path=\(socketPath)",
      ].joined(separator: "\n")
    case .rpcFailure(let failure):
      var lines = [
        "error_kind=rpc",
        "error_code=\(failure.code)",
        "message=\(failure.message)",
      ]
      if let cause = failure.cause {
        if !cause.isEmpty {
          lines.append("cause=\(cause)")
        }
      }
      return lines.joined(separator: "\n")
    case .transportFailure(let message):
      return [
        "error_kind=transport",
        "message=\(message)",
      ].joined(separator: "\n")
    case .usage(let message):
      return [
        "error_kind=usage",
        "message=\(message)",
      ].joined(separator: "\n")
    }
  }
}

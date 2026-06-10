//
//  RelayScreenModel.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-02.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import SwiftUI

private let logger = CellTunnelLog.logger(category: .app)

// MARK: - Constants

private let emptyValuePlaceholder = "(none)"
private let openLoginItemsTitle = "Open Login Items"
private let dataSectionTitle = "Data"
private let currentSpeedSectionTitle = "Current Speed"
private let bytesCountStyle = ByteCountFormatStyle(style: .file, spellsOutZero: false)

// MARK: - ConnectionRow

/// One label-and-value line inside a connection section. Rendering is data-driven,
/// so a new primitive becomes a new row with no change to the views. The label is
/// the stable identity, so a list change animates instead of replacing the row. A
/// qualifier row carries a constant such as the protocol name and does not count as
/// data when deciding whether its section has anything to show.
struct ConnectionRow: Identifiable, Equatable {
  let label: String
  let value: String
  var isQualifier = false

  var id: String { label }

  /// Whether the value has not arrived yet, so the Mac renders the row as a redacted
  /// skeleton placeholder rather than the literal placeholder text.
  var isPlaceholder: Bool {
    value == emptyValuePlaceholder
  }
}

// MARK: - ConnectionSection

/// One titled group of connection rows. The connection area renders an ordered
/// list of these, so adding a group is a data change, not a view change. The title
/// is the stable identity, so a section collapsing or appearing animates. A
/// qualifier such as the egress transport or the protocol is an ordinary first row,
/// so the header stays a plain Title Case header.
struct ConnectionSection: Identifiable, Equatable {
  let title: String
  let rows: [ConnectionRow]

  var id: String { title }
}

// MARK: - RelayUITier

/// Which screen the status renders. The two setup states take over the whole screen
/// with a single guided action; every other state shows the reduced dashboard with
/// its rows, peers, and action.
enum RelayUITier: Equatable {
  case full
  case reduced
}

// MARK: - RelayStatus

/// The relay status, the single value the whole status screen renders from. The seven
/// cases are the canonical states shared by the iPhone and the Mac, a set rather than
/// a precedence chain. The type owns its UI tier, its label, whether routing is
/// available, whether the live speed shows, and the offered action, so the views never
/// infer state from a pile of separate flags. The labels are neutral placeholders, not
/// final copy, and never use the banned words.
enum RelayStatus: Equatable {
  case error(String)
  case noAgent
  case noPeerSelected
  case noPeersFound
  case noTunnelInstalled
  case passthrough
  case relayEnabled

  /// Builds the status from named, single-purpose inputs. A failure wins; then the
  /// agent must be present, then a saved tunnel. An established peer link decides the
  /// rest before discovery, since a live link means the screen is connected whether or
  /// not this side browsed for it: with the link up, routing on is relaying and routing
  /// off is passthrough. Without a link, no discovered peer is the searching state and a
  /// discovered-but-unconnected peer is the select state. `isAgentInstalled` is always
  /// true on the iPhone.
  init(
    errorMessage: String?,
    isAgentInstalled: Bool,
    isTunnelInstalled: Bool,
    peersFound: Bool,
    isPeerConnected: Bool,
    isRouting: Bool
  ) {
    if let errorMessage, !errorMessage.isEmpty {
      self = .error(errorMessage)
    } else if !isAgentInstalled {
      self = .noAgent
    } else if !isTunnelInstalled {
      self = .noTunnelInstalled
    } else if isPeerConnected {
      self = isRouting ? .relayEnabled : .passthrough
    } else if !peersFound {
      self = .noPeersFound
    } else {
      self = .noPeerSelected
    }
  }

  /// Which screen renders this state: a full guided setup for the two install states,
  /// the reduced dashboard for everything else.
  var uiTier: RelayUITier {
    switch self {
    case .noAgent, .noTunnelInstalled:
      return .full
    case .error, .noPeerSelected, .noPeersFound, .passthrough, .relayEnabled:
      return .reduced
    }
  }

  /// The neutral status word shown as the switch's left label and the reduced-tier
  /// status line.
  var label: String {
    switch self {
    case .error:
      return "Error"
    case .noAgent:
      return "Agent not installed"
    case .noPeerSelected:
      return "No peer selected"
    case .noPeersFound:
      return "Searching for peers"
    case .noTunnelInstalled:
      return "Tunnel not installed"
    case .passthrough:
      return "Passthrough"
    case .relayEnabled:
      return "Relay on"
    }
  }

  /// Whether the routing switch is usable. Only the two established-link states let
  /// the user choose passthrough versus relaying; the rest disable the switch.
  var allowsRouting: Bool {
    switch self {
    case .passthrough, .relayEnabled:
      return true
    case .error, .noAgent, .noPeerSelected, .noPeersFound, .noTunnelInstalled:
      return false
    }
  }

  /// Whether the live `Current Speed` section shows, only while relaying.
  var showsSpeed: Bool {
    self == .relayEnabled
  }

  /// The optional offered action for the current state. Passthrough and relaying
  /// offer no action beyond the routing switch itself.
  var action: RelayHeroAction? {
    switch self {
    case .error:
      return .retry
    case .noAgent:
      return .installAgent
    case .noTunnelInstalled:
      return .installTunnel
    case .noPeerSelected:
      return .selectPeer
    case .noPeersFound, .passthrough, .relayEnabled:
      return nil
    }
  }

  /// The error message when the status is an error, otherwise nil.
  var errorMessage: String? {
    guard case .error(let message) = self else {
      return nil
    }
    return message
  }
}

// MARK: - RelayHeroAction

/// The offered call to action for the current state. Each case maps to one controller
/// operation, so the view holds no branching of its own. `selectPeer` is offered by
/// the reduced-tier peers list rather than a single button.
enum RelayHeroAction: Equatable {
  case installAgent
  case installTunnel
  case retry
  case selectPeer

  /// The button title shown in the action row.
  var title: String {
    switch self {
    case .installAgent:
      return "Install Agent"
    case .installTunnel:
      return "Install Tunnel"
    case .retry:
      return "Retry"
    case .selectPeer:
      return "Select Peer"
    }
  }

  /// The SF Symbol shown beside the action on the setup screen.
  var systemImage: String {
    switch self {
    case .installAgent:
      return "gearshape.2"
    case .installTunnel:
      return "arrow.down.doc"
    case .retry:
      return "arrow.clockwise"
    case .selectPeer:
      return "person.crop.circle.badge.checkmark"
    }
  }
}

// MARK: - RelayScreenModel

/// The one source the status screen renders from, on both the iPhone and the Mac.
/// It reads the observable `RelayController` and derives the screen state, the
/// optional action, and the data-driven sections, so the views hold no platform
/// branches and no display logic of their own.
@MainActor
struct RelayScreenModel {
  let controller: RelayController

  // MARK: - Status

  /// The relay status, built from the controller's published signals through named,
  /// single-purpose inputs. The relay can carry traffic only with the peer, so the
  /// peer is the gate; the local interface flag (`isRunning`) is not an input. Both
  /// screens read `status.label`, `status.allowsRouting`, and `status.showsSpeed`.
  var status: RelayStatus {
    RelayStatus(
      errorMessage: controller.lastError,
      isAgentInstalled: controller.isAgentInstalled,
      isTunnelInstalled: controller.isTunnelInstalled,
      peersFound: !controller.discoveredPeers.isEmpty,
      isPeerConnected: controller.connectedPeerName != nil,
      isRouting: controller.routeState == .installed
    )
  }

  /// Whether a usable tunnel configuration exists. The iPhone root view gates its
  /// setup screen on this flag directly, because on iPhone a denial error must keep
  /// the setup screen rather than switch to the error dashboard.
  var isTunnelInstalled: Bool {
    controller.isTunnelInstalled
  }

  /// Which screen the status renders: full guided setup or the reduced dashboard.
  var uiTier: RelayUITier {
    status.uiTier
  }

  /// Whether the routing switch shows at all. The switch appears only in a routeable
  /// state, so it is absent rather than disabled when no link can carry traffic, and
  /// the status word reports the state on its own.
  var showsToggle: Bool {
    status.allowsRouting
  }

  /// The `Route traffic` switch binding: it reads the routing state and writes the
  /// user's choice through the controller, which forwards it to the agent. Both the
  /// iPhone list and the Mac dashboard bind the switch to this, so the glue lives once.
  var routeTrafficBinding: Binding<Bool> {
    Binding(
      get: { controller.displayedRouting },
      set: { newValue in
        Task { await controller.setRouteTraffic(enabled: newValue) }
      }
    )
  }

  /// Whether a routing request is awaiting the agent's confirmation, so the screen
  /// shows a spinner beside the switch while the real `routeState` catches up.
  var isRouteRequestPending: Bool {
    controller.isRouteRequestPending
  }

  /// Brings the relay session up, the action behind `Retry`.
  func startSession() {
    logger.notice("relay screen start requested")
    Task { await controller.start() }
  }

  // MARK: - Action

  /// The optional offered action for the current status, owned by the status itself.
  var heroAction: RelayHeroAction? {
    status.action
  }

  /// Installs the background agent, or opens Login Items when the agent is registered
  /// but awaiting approval. The install-agent setup action.
  func installAgent() {
    logger.notice("relay screen install agent requested")
    if controller.isAgentApprovalPending {
      controller.openLoginItems()
    } else {
      controller.installAgent()
    }
  }

  /// Installs the tunnel profile from the imported configuration. The install-tunnel
  /// setup action.
  func installTunnel(configURL: URL) {
    logger.notice("relay screen install tunnel requested")
    Task { await controller.installTunnel(configURL: configURL) }
  }

  /// Selects the discovered peer to connect to, the reduced-tier peers control.
  func selectPeer(id: String) {
    logger.notice("relay screen select peer requested")
    Task { await controller.selectPeer(id: id) }
  }

  /// The title for the setup screen's primary action, deferring to the agent
  /// approval state when the agent is registered but pending.
  var setupActionTitle: String {
    if status.action == .installAgent, controller.isAgentApprovalPending {
      return openLoginItemsTitle
    }
    return status.action?.title ?? ""
  }

  /// The runtime error message when the status is an error, shown as a row.
  var errorMessage: String? {
    status.errorMessage
  }

  // MARK: - Peers

  /// The discovered peers, the selected peer's id, and whether the peers group shows.
  /// The group appears only once discovery has found peers and none is selected, so the
  /// user can pick a Mac to relay through. While discovery has found nothing the header
  /// already reads the searching state, so the group stays hidden to avoid repeating it.
  var discoveredPeers: [TunnelRelayService] {
    controller.discoveredPeers
  }

  var selectedPeerID: String? {
    controller.selectedPeerID
  }

  var showsPeers: Bool {
    switch status {
    case .noPeerSelected:
      return true
    case .error, .noAgent, .noPeersFound, .noTunnelInstalled, .passthrough, .relayEnabled:
      return false
    }
  }

  // MARK: - Sections

  /// Every section the status screen renders, in order: the lifetime `Data`, the
  /// live `Current Speed` while routing, then the connection sections that have a
  /// value. Both the iPhone list and the Mac dashboard render this one list, so the
  /// section set and ordering live in one place.
  var sections: [ConnectionSection] {
    var result = [dataSection]
    if let currentSpeedSection {
      result.append(currentSpeedSection)
    }
    result.append(contentsOf: connectionSections)
    return result
  }

  // MARK: - Mac

  /// Every section in order for the Mac, with placeholder rows dropped but empty
  /// sections kept, so the Mac shows its full structure rather than collapsing to a
  /// single card. The iPhone uses `sections`, which drops empty sections entirely.
  var macSections: [ConnectionSection] {
    var result = [dataSection]
    if let currentSpeedSection {
      result.append(currentSpeedSection)
    }
    let connection = [deviceSection, peerSection, relaySection]
    result.append(contentsOf: connection.map(macRows))
    return result
  }

  // A section that has a real value drops its placeholder rows; a section with no
  // value keeps its full rows so the Mac can render them as redacted skeletons, which
  // shows the structure without printing a placeholder string.
  private func macRows(_ section: ConnectionSection) -> ConnectionSection {
    hasData(section) ? visibleRows(section) : section
  }

  // MARK: - Data

  // The lifetime bytes sent, received, and their sum. The controller accumulates
  // each direction across sessions, so the figures persist across a restart.
  private var dataSection: ConnectionSection {
    ConnectionSection(
      title: dataSectionTitle,
      rows: [
        ConnectionRow(
          label: "Transferred",
          value: formattedBytes(controller.lifetimeTransferredBytes)
        ),
        ConnectionRow(
          label: "Received",
          value: formattedBytes(controller.lifetimeReceivedBytes)
        ),
        ConnectionRow(
          label: "Total",
          value: formattedBytes(controller.lifetimeTotalBytes)
        ),
      ]
    )
  }

  // MARK: - Current Speed

  // The live Up and Down rates, shown only while relaying, where the Mac's traffic
  // crosses the tunnel; `nil` otherwise so the section is absent.
  private var currentSpeedSection: ConnectionSection? {
    guard status.showsSpeed else {
      return nil
    }
    return ConnectionSection(
      title: currentSpeedSectionTitle,
      rows: [
        ConnectionRow(label: "Up", value: formattedRate(controller.uploadMbps)),
        ConnectionRow(label: "Down", value: formattedRate(controller.downloadMbps)),
      ]
    )
  }

  // MARK: - Connection

  /// The ordered connection sections that have something to show, each carrying only
  /// its visible rows. A section with no known value collapses and a placeholder row
  /// is dropped, so a not-connected screen shows only what it knows and no `(none)`
  /// row appears; the sections animate in and out as values arrive. A section counts
  /// as having data when any non-qualifier row holds a value other than the
  /// placeholder, and a qualifier such as the protocol stays whenever its section does.
  var connectionSections: [ConnectionSection] {
    [deviceSection, peerSection, relaySection]
      .filter(hasData)
      .map(visibleRows)
  }

  private func hasData(_ section: ConnectionSection) -> Bool {
    section.rows.contains { row in
      !row.isQualifier && row.value != emptyValuePlaceholder
    }
  }

  private func visibleRows(_ section: ConnectionSection) -> ConnectionSection {
    ConnectionSection(
      title: section.title,
      rows: section.rows.filter { row in
        row.isQualifier || row.value != emptyValuePlaceholder
      }
    )
  }

  // MARK: - Formatting

  private func formattedRate(_ value: Double) -> String {
    String(format: "%.1f Mbps", value)
  }

  // ByteCountFormatStyle formats Int64, so the unsigned lifetime total is clamped
  // into the signed range before formatting; real byte totals stay well inside it.
  private func formattedBytes(_ value: UInt64) -> String {
    let clamped = Int64(min(value, UInt64(Int64.max)))
    return bytesCountStyle.format(clamped)
  }

  // This device: the egress transport with its interface id, the egress interface
  // addresses, this device's own address on the carrying link, and its public
  // address. Every row is a local-side fact, so they share the one card.
  private var deviceSection: ConnectionSection {
    let egress = ConnectionRow(
      label: "Interface",
      value: transportLabel(
        controller.cellularPath.transportDisplayName,
        interface: controller.cellularPath.interfaceName
      )
    )
    var rows = [egress]
    rows.append(contentsOf: interfaceAddressRows())
    rows.append(
      ConnectionRow(
        label: "Link IP",
        value: nonEmptyOrPlaceholder(controller.localLinkAddresses.preferredAddress)
      )
    )
    rows.append(contentsOf: addressRows(prefix: "Public", controller.devicePublicAddresses))
    return ConnectionSection(title: "This Device", rows: rows)
  }

  // The other device: the connected peer name, the carrying transport with its raw
  // interface, the peer's address on the carrying link, and the peer's public
  // address. Every row is a fact about the peer, so they share the one card.
  private var peerSection: ConnectionSection {
    var rows = [
      ConnectionRow(label: "Connected to", value: connectedToValue),
      ConnectionRow(label: "Connected via", value: connectedViaValue),
      ConnectionRow(
        label: "Link IP",
        value: nonEmptyOrPlaceholder(controller.peerLinkAddresses.preferredAddress)
      ),
    ]
    rows.append(contentsOf: addressRows(prefix: "Public", controller.peerPublicAddresses))
    return ConnectionSection(title: "Peer", rows: rows)
  }

  // The WireGuard relay: the protocol, the configured endpoint hostname, and the
  // server's addresses resolved from that hostname.
  private var relaySection: ConnectionSection {
    var rows = [
      ConnectionRow(
        label: "Protocol",
        value: nonEmptyOrPlaceholder(controller.relayProtocol),
        isQualifier: true
      ),
      ConnectionRow(label: "Host", value: nonEmptyOrPlaceholder(controller.relayHost)),
    ]
    rows.append(contentsOf: addressRows(prefix: "", relayServerAddresses))
    return ConnectionSection(title: "Relay", rows: rows)
  }

  // The egress interface's full address list: one row per family with every
  // non-link-local address on its own line. The controller recomputes this once
  // per poll off the render path, so the rows read the cached value rather than
  // calling getifaddrs on every SwiftUI body evaluation.
  private func interfaceAddressRows() -> [ConnectionRow] {
    let all = controller.interfaceAddresses
    return [
      ConnectionRow(label: "Interface IPv6", value: joinedOrPlaceholder(all.ipv6)),
      ConnectionRow(label: "Interface IPv4", value: joinedOrPlaceholder(all.ipv4)),
    ]
  }

  // Joins every address onto its own line, or the placeholder when the family has
  // none, so a row renders one address per line.
  private func joinedOrPlaceholder(_ values: [String]) -> String {
    values.isEmpty ? emptyValuePlaceholder : values.joined(separator: "\n")
  }

  private var relayServerAddresses: AddressPair {
    AddressPair(
      ipv4: controller.relayServerIPv4Address,
      ipv6: controller.relayServerIPv6Address
    )
  }

  // An IPv6 then IPv4 pair, IPv6 first per the design, each falling back to a
  // labeled placeholder so no row is blank. The prefix names the pair's origin
  // (`Interface`, `Public`, `Local link`, `Peer link`); an empty prefix labels the
  // bare `IPv6`/`IPv4` of the relay server.
  private func addressRows(prefix: String, _ pair: AddressPair) -> [ConnectionRow] {
    let ipv6Label = prefix.isEmpty ? "IPv6" : "\(prefix) IPv6"
    let ipv4Label = prefix.isEmpty ? "IPv4" : "\(prefix) IPv4"
    return [
      ConnectionRow(label: ipv6Label, value: nonEmptyOrPlaceholder(pair.ipv6)),
      ConnectionRow(label: ipv4Label, value: nonEmptyOrPlaceholder(pair.ipv4)),
    ]
  }

  private var connectedToValue: String {
    nonEmptyOrPlaceholder(controller.connectedPeerName)
  }

  private var connectedViaValue: String {
    transportLabel(
      controller.localLinkClass?.displayName,
      interface: controller.localLinkInterfaceName
    )
  }

  // `name (interface)`, or `name` alone when the interface id is absent, falling
  // back to the placeholder when the transport name is absent. Both `Egress` and
  // `Connected via` render the transport-with-id format through this.
  private func transportLabel(_ name: String?, interface: String?) -> String {
    guard let name, !name.isEmpty else {
      return emptyValuePlaceholder
    }
    guard let interface, !interface.isEmpty else {
      return name
    }
    return "\(name) (\(interface))"
  }

  private func nonEmptyOrPlaceholder(_ value: String?) -> String {
    guard let value, !value.isEmpty else {
      return emptyValuePlaceholder
    }
    return value
  }
}

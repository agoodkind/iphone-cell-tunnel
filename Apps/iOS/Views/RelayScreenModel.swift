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
private let wireGuardProtocolName = "WireGuard"
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

// MARK: - RelayScreenState

/// The single state that drives the whole status screen. Every case has a defined
/// zero state in the section data the model builds, so the views never render an
/// unlabeled value.
enum RelayScreenState: Equatable {
    case connecting
    case disconnected
    case error(String)
    case noCellular
    case notSetUp
    case passthrough
    case routing
    case starting

    /// Whether the routing-only `Current Speed` section is shown.
    var showsSpeed: Bool {
        self == .routing
    }

    /// Whether the routing switch is disabled. It is enabled only when the peer link
    /// is up and routing can actually be turned on, the `passthrough` and `routing`
    /// states; every other state disables it.
    var disablesControls: Bool {
        switch self {
        case .passthrough, .routing:
            return false
        case .connecting, .disconnected, .error, .noCellular, .notSetUp, .starting:
            return true
        }
    }
}

// MARK: - RelayHeroAction

/// The optional call to action for the current state, rendered as a button row in
/// the status section. Each case maps to one controller operation, so the view holds
/// no branching of its own.
enum RelayHeroAction: Equatable {
    case retry
    case setUp

    /// The button title shown in the action row.
    var title: String {
        switch self {
        case .retry:
            return "Retry"
        case .setUp:
            return "Set Up"
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

    // MARK: - State

    /// The derived screen state from the controller's published status.
    var state: RelayScreenState {
        if let error = controller.lastError, !error.isEmpty {
            return .error(error)
        }
        if controller.isStarting, !controller.isRunning {
            return .starting
        }
        guard controller.peerState != .notSelected || controller.isRunning else {
            return .notSetUp
        }
        guard controller.isRunning else {
            return .disconnected
        }
        if controller.connectedPeerName == nil {
            return .connecting
        }
        if !controller.cellularPath.isSatisfied {
            return .noCellular
        }
        return controller.routeState == .installed ? .routing : .passthrough
    }

    /// The lifecycle status shown as the switch's left label. The wording names each
    /// phase, separating the relay coming up from reaching the peer, and reads as not
    /// routing in passthrough.
    var statusLabel: String {
        switch state {
        case .notSetUp:
            return "Not set up"
        case .starting:
            return "Starting relay…"
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting to peer…"
        case .noCellular:
            return "No network"
        case .passthrough:
            return "Ready to route"
        case .routing:
            return "Routing"
        case .error:
            return "Error"
        }
    }

    /// The `Route traffic` switch binding: it reads the routing state and writes the
    /// user's choice through the controller, which forwards it to the agent. Both the
    /// iPhone list and the Mac dashboard bind the switch to this, so the glue lives once.
    var routeTrafficBinding: Binding<Bool> {
        Binding(
            get: { controller.routeState == .installed },
            set: { newValue in
                Task { await controller.setRouteTraffic(enabled: newValue) }
            }
        )
    }

    /// Brings the relay session up, the action behind both `Set Up` and `Retry`.
    func startSession() {
        logger.notice("relay screen start requested")
        Task { await controller.start() }
    }

    // MARK: - Action

    /// The optional action for the current state: `Set Up` before a session exists,
    /// `Retry` after an error, nil otherwise. Shown as a row in the status section,
    /// since the screen is always the full list rather than a centered hero.
    var heroAction: RelayHeroAction? {
        switch state {
        case .notSetUp:
            return .setUp
        case .error:
            return .retry
        default:
            return nil
        }
    }

    /// The runtime error message when the state is an error, shown as a row.
    var errorMessage: String? {
        guard case .error(let message) = state else {
            return nil
        }
        return message
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

    // The live Up and Down rates, shown only in the routing state where the Mac's
    // traffic crosses the tunnel; `nil` otherwise so the section is absent.
    private var currentSpeedSection: ConnectionSection? {
        guard state.showsSpeed else {
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
        [connectionSection, deviceSection, peerSection, relaySection]
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

    // The peer the phone is connected to, the carrying link transport with its raw
    // interface, and the link's local and peer addresses. The link is one connection
    // over one family, so each end is one address, not an IPv6/IPv4 pair.
    private var connectionSection: ConnectionSection {
        let rows = [
            ConnectionRow(label: "Connected to", value: connectedToValue),
            ConnectionRow(label: "Connected via", value: connectedViaValue),
            ConnectionRow(
                label: "Local link",
                value: nonEmptyOrPlaceholder(controller.localLinkAddresses.preferredAddress)
            ),
            ConnectionRow(
                label: "Peer link",
                value: nonEmptyOrPlaceholder(controller.peerLinkAddresses.preferredAddress)
            ),
        ]
        return ConnectionSection(title: "Connection", rows: rows)
    }

    // This device: the egress transport with its interface id, the egress interface
    // addresses, and this device's effective public address.
    private var deviceSection: ConnectionSection {
        let egress = ConnectionRow(
            label: "Egress",
            value: transportLabel(
                controller.cellularPath.transportDisplayName,
                interface: controller.cellularPath.interfaceName
            )
        )
        var rows = [egress]
        rows.append(contentsOf: addressRows(prefix: "Interface", egressInterfaceAddresses))
        rows.append(contentsOf: addressRows(prefix: "Public", controller.devicePublicAddresses))
        return ConnectionSection(title: "Device", rows: rows)
    }

    // The peer's effective public address, measured by the peer and received over the
    // control link.
    private var peerSection: ConnectionSection {
        ConnectionSection(
            title: "Peer",
            rows: addressRows(prefix: "Public", controller.peerPublicAddresses)
        )
    }

    // The WireGuard relay: the protocol, the configured endpoint hostname, and the
    // server's addresses resolved from that hostname.
    private var relaySection: ConnectionSection {
        var rows = [
            ConnectionRow(label: "Protocol", value: wireGuardProtocolName, isQualifier: true),
            ConnectionRow(label: "Host", value: nonEmptyOrPlaceholder(controller.relayHost)),
        ]
        rows.append(contentsOf: addressRows(prefix: "", relayServerAddresses))
        return ConnectionSection(title: "Relay", rows: rows)
    }

    // The egress interface addresses and the resolved relay server addresses, the two
    // pairs the controller carries as separate fields, wrapped so every pair renders
    // through one builder.
    private var egressInterfaceAddresses: AddressPair {
        AddressPair(
            ipv4: controller.cellularPath.ipv4Address,
            ipv6: controller.cellularPath.ipv6Address
        )
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

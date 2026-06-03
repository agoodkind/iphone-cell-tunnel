//
//  RelayScreenModel.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-02.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import SwiftUI

// MARK: - Constants

private let emptyValuePlaceholder = "(none)"
private let cellularQualifier = "Cellular"
private let wireGuardQualifier = "WireGuard"

// MARK: - LocalLinkTransport

/// The Mac-to-iPhone link transport, by defined name. Raw interface identifiers
/// such as `en0` or `pdp_ip0` never reach the screen; they map to one of these
/// cases first, so the connection rows always read a stable user-facing name.
enum LocalLinkTransport: Equatable {
    case ethernet
    case peerToPeer
    case unknown
    case usb
    case wiFi

    /// Maps a raw interface identifier to a defined transport. The mapping follows
    /// the link transports the architecture describes: a CDC-NCM Ethernet-over-USB
    /// link, a USB-C Ethernet adapter, Wi-Fi LAN, and AWDL peer-to-peer.
    static func from(interfaceName: String?) -> LocalLinkTransport {
        guard let interfaceName, !interfaceName.isEmpty else {
            return .unknown
        }
        let lowercased = interfaceName.lowercased()
        if lowercased.hasPrefix("en") {
            return .wiFi
        }
        if lowercased.hasPrefix("awdl") || lowercased.hasPrefix("llw") {
            return .peerToPeer
        }
        if lowercased.contains("ncm") || lowercased.contains("usb") {
            return .usb
        }
        if lowercased.hasPrefix("bridge") || lowercased.hasPrefix("eth") {
            return .ethernet
        }
        return .unknown
    }

    /// The user-facing name shown on the `Connected via` row.
    var displayName: String {
        switch self {
        case .usb:
            return "USB"
        case .wiFi:
            return "Wi-Fi"
        case .peerToPeer:
            return "Peer-to-Peer"
        case .ethernet:
            return "Ethernet"
        case .unknown:
            return emptyValuePlaceholder
        }
    }
}

// MARK: - ConnectionRow

/// One label-and-value line inside a connection section. Rendering is data-driven,
/// so a new primitive becomes a new row with no change to the views.
struct ConnectionRow: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let value: String
}

// MARK: - ConnectionSection

/// One titled group of connection rows, with an optional right-aligned qualifier
/// such as `Cellular` or `WireGuard`. The connection area renders an ordered list
/// of these, so adding a group is a data change, not a view change. `secondaryRows`
/// render below the primary rows after a slight gap, empty when the group has none.
struct ConnectionSection: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let qualifier: String?
    let rows: [ConnectionRow]
    let secondaryRows: [ConnectionRow]
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

    /// Whether the `Route traffic` switch is shown. The switch appears only once a
    /// link to the iPhone is up.
    var showsRouteSwitch: Bool {
        switch self {
        case .passthrough, .routing:
            return true
        case .notSetUp, .disconnected, .connecting, .noCellular, .error:
            return false
        }
    }

    /// Whether the routing-only `SPEED` section is shown.
    var showsSpeed: Bool {
        self == .routing
    }

    /// Whether the `DATA` and `CONNECTION` sections are shown. They are hidden only
    /// before the tunnel is set up.
    var showsTunnelDetail: Bool {
        switch self {
        case .notSetUp:
            return false
        case .disconnected, .connecting, .passthrough, .routing, .noCellular, .error:
            return true
        }
    }

    /// Whether controls are disabled, used while connecting.
    var disablesControls: Bool {
        self == .connecting
    }
}

// MARK: - RelayHeroAction

/// The optional call to action a hero offers, rendered as the `ContentUnavailableView`
/// action button. Each case maps to one controller operation, so the view holds no
/// branching of its own.
enum RelayHeroAction: Equatable {
    case retry
    case setUp

    /// The button title shown inside the hero.
    var title: String {
        switch self {
        case .retry:
            return "Retry"
        case .setUp:
            return "Set Up"
        }
    }
}

// MARK: - RelayScreenHero

/// The hero presentation for the current state, rendered by `ContentUnavailableView`:
/// a `Label` built from an SF Symbol and a title, a short description, and an
/// optional action. The icon name is always an SF Symbol.
struct RelayScreenHero: Equatable {
    let symbolName: String
    let title: String
    let subtitle: String?
    let action: RelayHeroAction?
}

// MARK: - RelayScreenModel

/// The one source the status screen renders from, on both the iPhone and the Mac.
/// It reads the observable `RelayController` and derives the screen state, the
/// hero, and the data-driven sections, so the views hold no platform branches and
/// no display logic of their own.
@MainActor
struct RelayScreenModel {
    let controller: RelayController

    // MARK: - State

    /// The derived screen state from the controller's published status.
    var state: RelayScreenState {
        if let error = controller.lastError, !error.isEmpty {
            return .error(error)
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

    /// Whether the `Route traffic` switch reads as on. On means routing.
    var routeTrafficEnabled: Bool {
        controller.routeState == .installed
    }

    // MARK: - Hero

    /// The hero for the current state.
    var hero: RelayScreenHero {
        switch state {
        case .notSetUp:
            return RelayScreenHero(
                symbolName: "circle.dashed",
                title: "Not set up",
                subtitle: "Route this device's internet through your iPhone's cellular.",
                action: .setUp
            )
        case .disconnected:
            return RelayScreenHero(
                symbolName: "bolt.horizontal.circle",
                title: "Disconnected",
                subtitle: "Waiting for iPhone…",
                action: nil
            )
        case .connecting:
            return RelayScreenHero(
                symbolName: "arrow.triangle.2.circlepath.circle",
                title: "Connecting…",
                subtitle: "Bringing the tunnel up…",
                action: nil
            )
        case .passthrough:
            return RelayScreenHero(
                symbolName: "circle.lefthalf.filled",
                title: "Passthrough",
                subtitle: "Connected. Turn on Route traffic to route this device.",
                action: nil
            )
        case .routing:
            return RelayScreenHero(
                symbolName: "circle.fill",
                title: "Routing",
                subtitle: "This device's traffic routes through the iPhone's cellular.",
                action: nil
            )
        case .noCellular:
            return RelayScreenHero(
                symbolName: "antenna.radiowaves.left.and.right.slash",
                title: "No cellular on iPhone",
                subtitle: "Waiting for a cellular path…",
                action: nil
            )
        case .error(let message):
            return RelayScreenHero(
                symbolName: "exclamationmark.triangle",
                title: "Something went wrong",
                subtitle: message,
                action: .retry
            )
        }
    }

    // MARK: - Speed

    /// The download rate, in Mbps, for the `SPEED` section.
    var downloadMbps: Double {
        controller.downloadMbps
    }

    /// The upload rate, in Mbps, for the `SPEED` section.
    var uploadMbps: Double {
        controller.uploadMbps
    }

    // MARK: - Data

    /// The lifetime total bytes through the tunnel for the `DATA` section. The
    /// controller accumulates the relay byte total across sessions, so the figure
    /// persists rather than resetting when a session restarts.
    var lifetimeTotalBytes: UInt64 {
        controller.lifetimeTotalBytes
    }

    // MARK: - Connection

    /// The ordered connection sections for the current state. Empty when the tunnel
    /// detail is hidden. The device and relay address groups appear once connected,
    /// even before their addresses are known, so the zero state is a labeled
    /// placeholder rather than a missing group. IPv6 always lists before IPv4, and
    /// every value falls back to a defined placeholder so no row is ever blank.
    var connectionSections: [ConnectionSection] {
        guard state.showsTunnelDetail else {
            return []
        }
        var sections = [overviewSection]
        guard showsAddressGroups else {
            return sections
        }
        sections.append(deviceSection)
        sections.append(endpointSection)
        return sections
    }

    // The address groups belong to a live connection, so they show in passthrough
    // and routing and stay hidden while disconnected, connecting, or in an edge.
    private var showsAddressGroups: Bool {
        switch state {
        case .passthrough, .routing:
            return true
        case .notSetUp, .disconnected, .connecting, .noCellular, .error:
            return false
        }
    }

    private var overviewSection: ConnectionSection {
        ConnectionSection(
            title: "Connection",
            qualifier: nil,
            rows: [
                ConnectionRow(label: "Connected to", value: connectedToValue),
                ConnectionRow(label: "Connected via", value: connectedViaValue),
            ],
            secondaryRows: []
        )
    }

    // The device section shows the iPhone's own cellular interface addresses, then
    // the public addresses the internet sees from the iPhone. A family with no
    // address shows the placeholder.
    private var deviceSection: ConnectionSection {
        ConnectionSection(
            title: "Device",
            qualifier: cellularQualifier,
            rows: addressRows(
                ipv6: controller.cellularPath.ipv6Address,
                ipv4: controller.cellularPath.ipv4Address
            ),
            secondaryRows: publicAddressRows(ipv6: nil, ipv4: nil)
        )
    }

    // The endpoint section shows the WireGuard server endpoint, then the public
    // addresses traffic egresses through. The endpoint IPv6 and the public IPv6 are
    // the same address by design. The public rows wait on the public-address probe.
    private var endpointSection: ConnectionSection {
        ConnectionSection(
            title: "Endpoint",
            qualifier: wireGuardQualifier,
            rows: addressRows(
                ipv6: controller.relayPublicIPv6Address,
                ipv4: controller.relayPublicIPv4Address
            ),
            secondaryRows: publicAddressRows(ipv6: nil, ipv4: nil)
        )
    }

    // The address group always shows both families, so the zero state is a labeled
    // placeholder rather than a missing row. IPv6 lists before IPv4 per the design.
    private func addressRows(ipv6: String?, ipv4: String?) -> [ConnectionRow] {
        [
            ConnectionRow(label: "IPv6", value: nonEmptyOrPlaceholder(ipv6)),
            ConnectionRow(label: "IPv4", value: nonEmptyOrPlaceholder(ipv4)),
        ]
    }

    // The public address pair shown below the interface or endpoint pair, IPv6
    // first and always present. Both wait on the public-address probe.
    private func publicAddressRows(ipv6: String?, ipv4: String?) -> [ConnectionRow] {
        [
            ConnectionRow(label: "Public IPv6", value: nonEmptyOrPlaceholder(ipv6)),
            ConnectionRow(label: "Public IPv4", value: nonEmptyOrPlaceholder(ipv4)),
        ]
    }

    private var connectedToValue: String {
        nonEmptyOrPlaceholder(controller.connectedPeerName)
    }

    private var connectedViaValue: String {
        LocalLinkTransport.from(interfaceName: controller.localLinkInterfaceName).displayName
    }

    private func nonEmptyOrPlaceholder(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return emptyValuePlaceholder
        }
        return value
    }
}

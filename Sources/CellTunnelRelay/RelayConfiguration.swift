//
//  RelayConfiguration.swift
//  CellTunnelRelay
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-04.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Network

// MARK: - RelayConfiguration

/// The single source of truth for the relay's interface choices: which interface
/// type the WireGuard egress pins to, and which interface carries the Mac link.
///
/// CONTRACT: these choices are set only here. No interface type and no interface
/// name is hardcoded in the binders, the data plane, or the composition presets;
/// each reads its value from this type. The defaults below are the values to write
/// for now. A later stored setting or UI control replaces them by constructing this
/// type differently at the composition root, with no change to the data plane or
/// the binders.
public struct RelayConfiguration: Sendable, Equatable {
    /// The interface type the WireGuard egress socket pins to on device. The
    /// cellular radio is the project's purpose, so it is the default.
    public var egressInterfaceType: NWInterface.InterfaceType

    /// The interface that carries the Mac link, overriding the score order. Nil uses
    /// the score order (wired over Wi-Fi LAN over peer-to-peer).
    public var preferredCarryingInterface: String?

    public init(
        egressInterfaceType: NWInterface.InterfaceType = .cellular,
        preferredCarryingInterface: String? = nil
    ) {
        self.egressInterfaceType = egressInterfaceType
        self.preferredCarryingInterface = preferredCarryingInterface
    }

    /// Today's values: cellular egress, score-order carrying link.
    public static let `default` = RelayConfiguration()
}

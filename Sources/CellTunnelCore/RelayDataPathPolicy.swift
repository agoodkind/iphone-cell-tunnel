//
//  RelayDataPathPolicy.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026
//

import Foundation

// MARK: - RelayDataPathPolicy

/// The single place that decides which network path the relay data plane uses
/// between the Mac and the iPhone. The control plane is low bandwidth and is not
/// governed here. This is the configurable knob the agent bridge, the iPhone
/// relay browser, and the iPhone relay connection all read, so the path policy
/// lives in one place rather than scattered booleans. A future change replaces
/// the static choice with an auto-probe that selects the fastest reachable path.
public enum RelayDataPathPolicy {
    /// Whether the relay data plane may use Apple peer-to-peer links (AWDL).
    /// Off keeps the data plane on the wired USB link and Wi-Fi LAN. AWDL is slow
    /// only while the device is also joined to a Wi-Fi network, since the one
    /// radio time-shares between the Wi-Fi channel and the AWDL channels; with no
    /// Wi-Fi connection AWDL can be much faster, so the fastest path is
    /// environment-dependent and the long-term answer is to auto-probe it rather
    /// than fix this flag. On adds AWDL as an additional candidate path.
    public static let includesPeerToPeer = false
}

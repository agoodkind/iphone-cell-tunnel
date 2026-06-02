//
//  WireGuardDatagramRelayState.swift
//  CellTunnelPhoneTunnel
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-29.
//  Copyright © 2026, all rights reserved.
//

import Foundation

/// Lifecycle of the iPhone relay's path to the WireGuard server: it starts
/// `stopped`, waits for the Mac to supply the server endpoint
/// (`waitingForHandshake`), dials the server (`connecting`), forwards once the
/// UDP connection is up (`ready`), and reports `failed` on connection failure.
enum WireGuardDatagramRelayState: String, Sendable {
    case connecting
    case failed
    case ready
    case stopped
    case waitingForHandshake

    var displayName: String {
        switch self {
        case .stopped:
            return "Stopped"
        case .waitingForHandshake:
            return "Waiting for endpoint"
        case .connecting:
            return "Connecting"
        case .ready:
            return "Ready"
        case .failed:
            return "Failed"
        }
    }
}

// MARK: - WireGuardDatagramRelayError

enum WireGuardDatagramRelayError: LocalizedError {
    case invalidServerPort(UInt16)
    case missingServerEndpoint
    case udpConnectionUnavailable

    var errorDescription: String? {
        switch self {
        case .missingServerEndpoint:
            return "WireGuard server endpoint is not configured"
        case .invalidServerPort(let port):
            return "WireGuard server port is invalid: \(port)"
        case .udpConnectionUnavailable:
            return "cellular WireGuard UDP connection is unavailable"
        }
    }
}

// MARK: - CellularWireGuardUDPState

enum CellularWireGuardUDPState: String, Sendable {
    case connecting
    case failed
    case ready
    case stopped
}

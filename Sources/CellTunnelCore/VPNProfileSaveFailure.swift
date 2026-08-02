//
//  VPNProfileSaveFailure.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-01.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Constants

/// The error domain the system uses for every VPN configuration failure.
private let vpnErrorDomain = "NEVPNErrorDomain"

/// The system's own codes, named here so the mapping below reads as a contract rather
/// than as numbers. The meanings come from the NetworkExtension headers.
private let configurationInvalidCode = 1
private let configurationStaleCode = 4
private let configurationWriteFailedCode = 5

// MARK: - VPNProfileSaveFailure

/// Why saving the tunnel's VPN profile did not work, in terms a person can act on.
///
/// Saving the profile is the moment macOS asks a person to allow a VPN configuration, and
/// it is also where a stale or malformed profile is refused. The system reports each of
/// those as a code in one error domain, and the text it carries names the failure without
/// naming a next step. Turning the code into both halves here means the daemon and every
/// client say the same thing, and the rule can be tested without a live prompt.
public enum VPNProfileSaveFailure: Equatable, Sendable {
  /// The profile itself was refused as invalid.
  case invalid
  /// The profile the app holds no longer matches what the system has stored.
  case stale
  /// The system would not write the profile. Declining the permission prompt is the
  /// common reason, which is why the remedy leads with it, and the wording stops short of
  /// claiming it because the same code also covers a genuine write failure.
  case writeRefused

  /// What happened, in a sentence a person can read.
  public var summary: String {
    switch self {
    case .writeRefused:
      return "macOS did not save the VPN configuration, most often because permission "
        + "to add it was declined."
    case .stale:
      return "Cell Tunnel's copy of the VPN configuration is out of date."
    case .invalid:
      return "macOS refused the VPN configuration."
    }
  }

  /// What to do about it.
  public var recovery: String {
    switch self {
    case .writeRefused:
      return "Turn routing on again and choose Allow."
    case .stale:
      return "Turn routing on again to save a fresh one."
    case .invalid:
      return "Check the configuration you selected, then turn routing on again."
    }
  }

  /// The full text a person should see: what happened, then what to do.
  public var message: String {
    "\(summary) \(recovery)"
  }
}

/// Classifies one profile-save failure, or nil when the failure is something else.
///
/// Only the codes with a distinct remedy are named. Anything else keeps whatever the
/// system said, because inventing a remedy for a failure this does not recognise would
/// send a person somewhere that cannot help them. A profile that is merely switched off
/// is deliberately absent: the status snapshot already reports that as its own state and
/// offers its own action.
public func vpnProfileSaveFailure(domain: String, code: Int) -> VPNProfileSaveFailure? {
  guard domain == vpnErrorDomain else {
    return nil
  }
  switch code {
  case configurationInvalidCode:
    return .invalid
  case configurationStaleCode:
    return .stale
  case configurationWriteFailedCode:
    return .writeRefused
  default:
    return nil
  }
}

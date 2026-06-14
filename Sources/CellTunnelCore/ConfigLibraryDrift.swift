//
//  ConfigLibraryDrift.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-14.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - ConfigLibraryDrift

/// The boot-time verdict comparing the running tunnel's stamped config id to the
/// library's active selection. The library is the source of truth, so this is a
/// non-mutating assertion: it never creates or changes a library row, it only
/// reports whether the downstream NEVPN projection agrees with the library.
public enum ConfigLibraryDrift: Equatable, Sendable {
  /// The running tunnel carries an id the library does not hold, or one that is not
  /// the active entry. This is a split-brain that must be surfaced loudly.
  case mismatch
  /// The running tunnel carries an id that is the library's active entry.
  case ok
  /// The running tunnel carries no config id, so it predates id-stamping or was
  /// started out-of-band. Trust the library; the next start or activate stamps it.
  case unstamped
}

/// Evaluates the boot-time config-library drift. Pure so the decision is tested
/// without NetworkExtension: a `nil` running id is `.unstamped`; a running id the
/// library does not hold, or one that is not `activeID`, is `.mismatch`; otherwise
/// `.ok`. The agent maps a present-but-unparseable NEVPN stamp to `.mismatch`
/// before calling, since that is a stamp it cannot honor.
public func evaluateConfigLibraryDrift(
  runningConfigID: UUID?,
  activeID: UUID?,
  libraryIDs: Set<UUID>
) -> ConfigLibraryDrift {
  guard let runningConfigID else {
    return .unstamped
  }
  guard libraryIDs.contains(runningConfigID) else {
    return .mismatch
  }
  if runningConfigID != activeID {
    return .mismatch
  }
  return .ok
}

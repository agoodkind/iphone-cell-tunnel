//
//  RelayLinkHealthTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import Testing

// MARK: - RelayLinkHealthTests

/// Covers the missing-link selection that drives self-heal. A known interface with
/// no open link must be re-dialed; an interface that has been pruned from the known
/// set (it went away) must not be, so the result never names a vanished interface.
struct RelayLinkHealthTests {
  // MARK: - A present interface with no link is re-dialed

  @Test func presentInterfaceWithNoLinkNeedsRedial() {
    let missing = RelayLinkHealth.interfacesNeedingRedial(
      known: ["en0"], open: []
    )
    #expect(missing == ["en0"])
  }

  // MARK: - A present interface that already has a link is left alone

  @Test func presentInterfaceWithLinkDoesNotNeedRedial() {
    let missing = RelayLinkHealth.interfacesNeedingRedial(
      known: ["en0"], open: ["en0"]
    )
    #expect(missing.isEmpty)
  }

  // MARK: - A pruned interface is never re-dialed

  @Test func prunedInterfaceIsNeverRedialed() {
    // en2 left the probe set, so it is absent from `known`; it must not appear.
    let missing = RelayLinkHealth.interfacesNeedingRedial(
      known: ["en0"], open: []
    )
    #expect(!missing.contains("en2"))
  }

  // MARK: - Only the unlinked subset is returned

  @Test func returnsOnlyKnownInterfacesWithoutLinks() {
    let missing = RelayLinkHealth.interfacesNeedingRedial(
      known: ["en0", "awdl0"], open: ["awdl0"]
    )
    #expect(missing == ["en0"])
  }

  // MARK: - Result is sorted for a stable dial order

  @Test func resultIsSortedForStableOrder() {
    let missing = RelayLinkHealth.interfacesNeedingRedial(
      known: ["en0", "awdl0", "anpi0"], open: []
    )
    #expect(missing == ["anpi0", "awdl0", "en0"])
  }

  // MARK: - No known interfaces means nothing to re-dial

  @Test func emptyKnownSetNeedsNoRedial() {
    let missing = RelayLinkHealth.interfacesNeedingRedial(
      known: [], open: ["en0"]
    )
    #expect(missing.isEmpty)
  }
}

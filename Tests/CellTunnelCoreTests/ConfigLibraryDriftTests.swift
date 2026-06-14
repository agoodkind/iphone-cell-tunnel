//
//  ConfigLibraryDriftTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-14.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import Foundation
import Testing

// MARK: - ConfigLibraryDriftTests

private let configOne = UUID()
private let configTwo = UUID()
private let configNine = UUID()

struct ConfigLibraryDriftTests {
  @Test func stampedActiveConfigIsOK() {
    let verdict = evaluateConfigLibraryDrift(
      runningConfigID: configOne, activeID: configOne, libraryIDs: [configOne, configTwo])

    #expect(verdict == .ok)
  }

  @Test func absentRunningIDIsUnstamped() {
    let verdict = evaluateConfigLibraryDrift(
      runningConfigID: nil, activeID: configOne, libraryIDs: [configOne])

    #expect(verdict == .unstamped)
  }

  @Test func runningIDNotInLibraryIsMismatch() {
    let verdict = evaluateConfigLibraryDrift(
      runningConfigID: configNine, activeID: configOne, libraryIDs: [configOne])

    #expect(verdict == .mismatch)
  }

  @Test func runningIDDiffersFromActiveIsMismatch() {
    let verdict = evaluateConfigLibraryDrift(
      runningConfigID: configTwo, activeID: configOne, libraryIDs: [configOne, configTwo])

    #expect(verdict == .mismatch)
  }
}

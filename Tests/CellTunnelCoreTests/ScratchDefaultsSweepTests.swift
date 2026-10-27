//
//  ScratchDefaultsSweepTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-27.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

// MARK: - ScratchDefaultsSweepTests

/// ScratchDefaultsSweepTests checks stale folder cleanup during creation.
/// The test starts /usr/bin/true, waits for it to exit, and plants a folder
/// containing defaults.plist under root using that process ID.
/// After creating a ScratchDefaults instance, the test checks that the stale
/// folder no longer exists and the new scratch folder exists until cleanup.
struct ScratchDefaultsSweepTests {
  private static let trueExecutablePath = "/usr/bin/true"
  private static let sweepLabel = "sweep"

  @Test func creationDeletesFolderOfExitedProcess() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: Self.trueExecutablePath)
    try process.run()
    process.waitUntilExit()
    let exitedProcessID = process.processIdentifier

    let fileManager = FileManager.default
    let staleProcessFolder = ScratchDefaults.rootDirectory.appendingPathComponent(
      String(exitedProcessID),
      isDirectory: true
    )
    let staleScratchFolder = staleProcessFolder.appendingPathComponent(
      "stale-\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.createDirectory(at: staleScratchFolder, withIntermediateDirectories: true)
    let plistContent: [String: String] = ["io.goodkind.celltunnel.relay.deviceID": "stale"]
    let plistData = try PropertyListSerialization.data(
      fromPropertyList: plistContent,
      format: .binary,
      options: 0
    )
    let stalePlist = staleScratchFolder.appendingPathComponent("defaults.plist")
    try plistData.write(to: stalePlist)
    #expect(fileManager.fileExists(atPath: stalePlist.path))

    ScratchDefaults.resetSweepForTesting()
    let currentProcessFolder = ScratchDefaults.rootDirectory.appendingPathComponent(
      String(ProcessInfo.processInfo.processIdentifier),
      isDirectory: true
    )
    try ScratchDefaults.run(label: Self.sweepLabel) { _ in
      #expect(!fileManager.fileExists(atPath: staleProcessFolder.path))
      let ownFolders = try fileManager.contentsOfDirectory(atPath: currentProcessFolder.path)
      let sweepFolders = ownFolders.filter { $0.hasPrefix("\(Self.sweepLabel)-") }
      #expect(sweepFolders.count == 1)
    }

    var remaining: [String] = []
    if fileManager.fileExists(atPath: currentProcessFolder.path) {
      remaining = try fileManager.contentsOfDirectory(atPath: currentProcessFolder.path)
    }
    let leftovers = remaining.filter { $0.hasPrefix("\(Self.sweepLabel)-") }
    #expect(leftovers.isEmpty)
  }
}

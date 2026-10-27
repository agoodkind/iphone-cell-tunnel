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

/// ScratchDefaultsSweepTests checks stale folder removal and the lifetime
/// of the test's own scratch folder through `ScratchDefaults.run`.
///
/// The test waits for a child process to exit before creating a folder for
/// that process ID. Inside the body, it checks that the stale folder does
/// not exist and its own folder exists. After `run` returns, it checks that
/// its own folder does not exist.
struct ScratchDefaultsSweepTests {
  private static let trueExecutablePath = "/usr/bin/true"
  private static let sweepLabel = "sweep"
  private static let plantedKey = "test-key"

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
    let plistContent: [String: String] = [Self.plantedKey: "stale"]
    let plistData = try PropertyListSerialization.data(
      fromPropertyList: plistContent,
      format: .binary,
      options: 0
    )
    let stalePlist = staleScratchFolder.appendingPathComponent("defaults.plist")
    try plistData.write(to: stalePlist)
    #expect(fileManager.fileExists(atPath: stalePlist.path))

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

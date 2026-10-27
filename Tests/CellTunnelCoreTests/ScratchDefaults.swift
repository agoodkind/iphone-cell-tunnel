//
//  ScratchDefaults.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-26.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation
import Synchronization
import struct OSLog.Logger

// MARK: - ScratchDefaults

/// ScratchDefaults creates a UserDefaults suite in a temporary folder.
/// An absolute suite name makes cfprefsd store the plist at <path>.plist,
/// outside ~/Library/Preferences.
///
/// run(label:body:) passes the suite to the body and keeps the ScratchDefaults
/// instance alive until the body returns. deinit removes the persistent domain,
/// deletes the scratch folder, and deletes the process folder when it is empty.
final class ScratchDefaults {
  // MARK: - Properties

  /// rootDirectory identifies celltunnel-scratch-defaults in the temporary directory.
  /// Each scratch folder uses <root>/<pid>/<label>-<UUID>/, where pid identifies
  /// the current process.
  static let rootDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("celltunnel-scratch-defaults", isDirectory: true)

  private static let processDirectory = rootDirectory.appendingPathComponent(
    String(ProcessInfo.processInfo.processIdentifier),
    isDirectory: true
  )

  /// The process-wide lock serializes folder creation and cleanup across parallel
  /// tests. A test cannot delete the empty process folder while another test
  /// creates a scratch folder inside it.
  private static let folderLock = NSLock()

  private static let sweepDone = Mutex(false)

  let suiteName: String
  let defaults: UserDefaults
  private let directory: URL

  // MARK: - Lifecycle

  private init(label: String) throws {
    try Self.sweepStaleFoldersOnce()
    let folderName = "\(label)-\(UUID().uuidString)"
    let folder = Self.processDirectory.appendingPathComponent(folderName, isDirectory: true)
    try Self.folderLock.withLock {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let name = folder.appendingPathComponent("defaults").path
    guard let suite = UserDefaults(suiteName: name) else {
      throw ScratchDefaultsError.suiteUnavailable(name)
    }
    suite.removePersistentDomain(forName: name)
    directory = folder
    suiteName = name
    defaults = suite
  }

  deinit {
    defaults.removePersistentDomain(forName: suiteName)
    Self.folderLock.withLock {
      removeOwnFolder()
      removeProcessFolderWhenEmpty()
    }
  }

  // MARK: - Cleanup

  private func removeOwnFolder() {
    do {
      try FileManager.default.removeItem(at: directory)
    } catch {
      let logger = CellTunnelLog.logger(category: .store)
      let folderPath = directory.path
      let reason = error.localizedDescription
      logger.error(
        """
        ScratchDefaults could not delete temporary folder \(folderPath, privacy: .public): \
        \(reason, privacy: .public)
        """
      )
    }
  }

  private func removeProcessFolderWhenEmpty() {
    let processFolder = Self.processDirectory
    do {
      let remaining = try FileManager.default.contentsOfDirectory(atPath: processFolder.path)
      if remaining.isEmpty {
        try FileManager.default.removeItem(at: processFolder)
      }
    } catch {
      let logger = CellTunnelLog.logger(category: .store)
      let folderPath = processFolder.path
      let reason = error.localizedDescription
      logger.error(
        """
        ScratchDefaults could not delete process folder \(folderPath, privacy: .public): \
        \(reason, privacy: .public)
        """
      )
    }
  }

  // MARK: - Stale folder sweep

  /// sweepStaleFolders() deletes process folders left after a process exits
  /// without cleanup. SIGKILL, an abort, or an Objective-C exception can prevent
  /// that cleanup.
  ///
  /// The first ScratchDefaults creation in a process triggers the sweep.
  /// The sweep preserves folders for running processes, including the current
  /// process, and logs each deletion with its path through CellTunnelLog.
  ///
  /// If a deletion fails, the sweep throws an error with the path and failure
  /// reason. Later ScratchDefaults creations retry the sweep.
  static func sweepStaleFolders() throws {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: rootDirectory.path) else {
      return
    }
    let currentProcessID = ProcessInfo.processInfo.processIdentifier
    let entries = try fileManager.contentsOfDirectory(
      at: rootDirectory,
      includingPropertiesForKeys: nil
    )
    let logger = CellTunnelLog.logger(category: .store)
    for entry in entries {
      guard let processID = Int32(entry.lastPathComponent), processID > 0 else {
        continue
      }
      guard processID != currentProcessID, isStale(processID: processID) else {
        continue
      }
      let folderPath = entry.path
      do {
        try fileManager.removeItem(at: entry)
      } catch {
        throw ScratchDefaultsError.sweepFailed(
          path: folderPath,
          reason: error.localizedDescription
        )
      }
      logger.notice(
        "ScratchDefaults deleted the stale process folder at \(folderPath, privacy: .public)."
      )
    }
  }

  /// isStale(processID:) reports that a process ID does not identify a running
  /// process only when kill(processID, 0) fails with ESRCH.
  private static func isStale(processID: Int32) -> Bool {
    if kill(processID, 0) == 0 {
      return false
    }
    return errno == ESRCH
  }

  private static func sweepStaleFoldersOnce() throws {
    try sweepDone.withLock { done in
      if done {
        return
      }
      try sweepStaleFolders()
      done = true
    }
  }

  /// resetSweepForTesting() resets the once-per-process sweep flag.
  /// A regression test can then plant a stale folder and trigger another sweep.
  static func resetSweepForTesting() {
    sweepDone.withLock { done in
      done = false
    }
  }

  // MARK: - Scoped use

  /// `run(label:body:)` creates a `ScratchDefaults`, passes its `UserDefaults` to
  /// `body`, and returns the result. `withExtendedLifetime` keeps the instance
  /// alive until `body` returns. `deinit` then removes the suite's persistent
  /// domain and deletes the temporary folder.
  static func run<Output>(
    label: String,
    body: (UserDefaults) throws -> Output
  ) throws -> Output {
    let scratch = try ScratchDefaults(label: label)
    return try withExtendedLifetime(scratch) {
      try body(scratch.defaults)
    }
  }
}

// MARK: - ScratchDefaultsError

enum ScratchDefaultsError: Error {
  case suiteUnavailable(String)
  case sweepFailed(path: String, reason: String)
}

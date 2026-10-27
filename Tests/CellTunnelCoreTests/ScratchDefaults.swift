//
//  ScratchDefaults.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-26.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation
import struct OSLog.Logger

// MARK: - ScratchDefaults

/// ScratchDefaults provides a UserDefaults suite in a temporary folder.
/// The suite name uses an absolute path. cfprefsd stores the plist at
/// `<path>.plist`, outside `~/Library/Preferences`.
///
/// Each scratch folder uses the layout `<root>/<pid>/<label>-<UUID>/`.
/// The root is `celltunnel-scratch-defaults` in the temporary directory,
/// and `pid` is the current process ID.
final class ScratchDefaults {
  // MARK: - Properties

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

  let suiteName: String
  let defaults: UserDefaults
  private let directory: URL
  private var isRemoved = false

  // MARK: - Lifecycle

  private init(label: String) throws {
    try Self.sweepStaleFolders()
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
    do {
      try remove()
    } catch {
      let logger = CellTunnelLog.logger(category: .store)
      let folderPath = directory.path
      let reason = error.localizedDescription
      logger.error(
        """
        ScratchDefaults could not remove scratch defaults folder \
        \(folderPath, privacy: .public) during deinit: \(reason, privacy: .public).
        """
      )
    }
  }

  // MARK: - Cleanup

  /// `remove()` removes the persistent domain and deletes the scratch folder
  /// under the process-wide folder lock. It also deletes the process folder
  /// when that folder is empty.
  ///
  /// A flag makes a second call return early.
  /// The method throws if deletion fails.
  func remove() throws {
    try Self.folderLock.withLock {
      if isRemoved {
        return
      }
      isRemoved = true
      defaults.removePersistentDomain(forName: suiteName)
      try FileManager.default.removeItem(at: directory)
      try Self.removeProcessFolderWhenEmpty()
    }
  }

  private static func removeProcessFolderWhenEmpty() throws {
    let remaining = try FileManager.default.contentsOfDirectory(atPath: processDirectory.path)
    if remaining.isEmpty {
      try FileManager.default.removeItem(at: processDirectory)
    }
  }

  // MARK: - Stale folder sweep

  /// `sweepStaleFolders()` deletes folders for processes that no longer run.
  /// Each ScratchDefaults creation runs the sweep. The sweep deletes a process
  /// folder only when `kill(pid, 0)` fails with `ESRCH`. It preserves folders
  /// for running processes, including the current process.
  ///
  /// Concurrent test processes can attempt to delete the same stale folder.
  /// If deletion reports `CocoaError.fileNoSuchFile` or `fileReadNoSuchFile`,
  /// another process already swept the folder. The sweep logs a notice and
  /// continues. Any other deletion failure throws an error with the path and
  /// reason. Each successful deletion logs one line with the path.
  /// The sweep uses CellTunnelLog for these messages.
  private static func sweepStaleFolders() throws {
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
      } catch let error as CocoaError where isAlreadyDeleted(error) {
        logger.notice(
          "Another process already swept scratch defaults folder \(folderPath, privacy: .public)."
        )
        continue
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

  private static func isAlreadyDeleted(_ error: CocoaError) -> Bool {
    error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
  }

  /// isStale(processID:) reports that a process ID does not identify a running
  /// process only when kill(processID, 0) fails with ESRCH.
  private static func isStale(processID: Int32) -> Bool {
    if kill(processID, 0) == 0 {
      return false
    }
    return errno == ESRCH
  }

  // MARK: - Scoped use

  /// `run(label:body:)` creates a `ScratchDefaults` instance and passes its
  /// `UserDefaults` to `body`. It keeps the instance alive until `body` finishes.
  /// It captures the body result or error, then calls `remove()` with `try`.
  ///
  /// If `remove()` succeeds, `run` returns the body result or rethrows the body error.
  /// If `remove()` throws after `body` succeeds, `run` throws the removal error.
  /// If both throw, `run` throws `ScratchDefaultsError.cleanupFailedAfterBodyError`.
  static func run<Output>(
    label: String,
    body: (UserDefaults) throws -> Output
  ) throws -> Output {
    let scratch = try ScratchDefaults(label: label)
    let result = withExtendedLifetime(scratch) {
      Result { try body(scratch.defaults) }
    }
    do {
      try scratch.remove()
    } catch {
      guard case .failure(let bodyError) = result else {
        throw error
      }
      throw ScratchDefaultsError.cleanupFailedAfterBodyError(
        bodyError: bodyError,
        path: scratch.directory.path,
        reason: error.localizedDescription
      )
    }
    return try result.get()
  }
}

// MARK: - ScratchDefaultsError

enum ScratchDefaultsError: Error {
  /// This error includes the body error, the scratch folder path, and the reason
  /// `remove()` failed.
  case cleanupFailedAfterBodyError(bodyError: any Error, path: String, reason: String)
  case suiteUnavailable(String)
  case sweepFailed(path: String, reason: String)
}

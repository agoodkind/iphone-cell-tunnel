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

/// ScratchDefaults provides a UserDefaults suite in a unique temporary folder
/// for tests.
final class ScratchDefaults {
  // MARK: - Properties

  /// The preferences service, cfprefsd, appends `.plist` to this absolute path
  /// and stores the file outside `~/Library/Preferences`.
  let suiteName: String
  let defaults: UserDefaults
  private let directory: URL

  // MARK: - Lifecycle

  private init(label: String) throws {
    let folderName = "\(label)-\(UUID().uuidString)"
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(folderName, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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
}

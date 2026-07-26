//
//  ConfigImportFile.swift
//  CellTunnelCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-21.
//  Copyright © 2026, all rights reserved.
//

import Foundation

#if os(macOS)
  import AppKit
  import Darwin
  import UniformTypeIdentifiers
#endif

// MARK: - ConfigImportFile

/// A configuration file's import name and raw WireGuard text.
public struct ConfigImportFile: Equatable, Sendable {
  public let name: String
  public let text: String

  public init(name: String, text: String) {
    self.name = name
    self.text = text
  }
}

// MARK: - ConfigImportFileLoading

/// Loads the configuration file named by a command-line path.
public protocol ConfigImportFileLoading: Sendable {
  func load(path: String) async throws -> ConfigImportFile
}

// MARK: - DirectConfigImportFileLoader

/// Reads configuration files that the command-line process can access directly.
public struct DirectConfigImportFileLoader: ConfigImportFileLoading {
  public init() {
    // This loader has no configurable state.
  }

  public func load(path: String) async throws -> ConfigImportFile {
    await Task.yield()
    let expandedPath = (path as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: expandedPath)
    return try readConfigImportFile(at: url)
  }
}

private func readConfigImportFile(at url: URL) throws -> ConfigImportFile {
  let text = try String(contentsOf: url, encoding: .utf8)
  let name = url.deletingPathExtension().lastPathComponent
  return ConfigImportFile(name: name, text: text)
}

#if os(macOS)
  let configImportAllowedContentTypes = [UTType.data]

  // MARK: - ConfigImportFileAccessing

  protocol ConfigImportFileAccessing: Sendable {
    func read(url: URL) throws -> ConfigImportFile
    func isPermissionDenied(_ error: Error) -> Bool
    func selectFile(suggestedURL: URL) async throws -> URL
    func startAccessingSecurityScope(url: URL) -> Bool
    func stopAccessingSecurityScope(url: URL)
  }

  // MARK: - MacOSConfigImportFileLoader

  /// Recovers a protected-file read by asking the user to select the file.
  public struct MacOSConfigImportFileLoader: ConfigImportFileLoading {
    private let fileAccess: any ConfigImportFileAccessing

    public init() {
      fileAccess = SystemConfigImportFileAccess()
    }

    init(fileAccess: any ConfigImportFileAccessing) {
      self.fileAccess = fileAccess
    }

    public func load(path: String) async throws -> ConfigImportFile {
      let expandedPath = (path as NSString).expandingTildeInPath
      let suggestedURL = URL(fileURLWithPath: expandedPath)
      do {
        return try fileAccess.read(url: suggestedURL)
      } catch {
        guard fileAccess.isPermissionDenied(error) else {
          throw error
        }
      }

      let selectedURL = try await fileAccess.selectFile(suggestedURL: suggestedURL)
      let accessing = fileAccess.startAccessingSecurityScope(url: selectedURL)
      defer {
        if accessing {
          fileAccess.stopAccessingSecurityScope(url: selectedURL)
        }
      }
      return try fileAccess.read(url: selectedURL)
    }
  }

  // MARK: - SystemConfigImportFileAccess

  private struct SystemConfigImportFileAccess: ConfigImportFileAccessing {
    func read(url: URL) throws -> ConfigImportFile {
      try readConfigImportFile(at: url)
    }

    func isPermissionDenied(_ error: Error) -> Bool {
      var currentError: NSError? = error as NSError
      while let candidate = currentError {
        if candidate.domain == NSCocoaErrorDomain,
          candidate.code == CocoaError.fileReadNoPermission.rawValue
        {
          return true
        }
        if candidate.domain == NSPOSIXErrorDomain,
          candidate.code == Int(EACCES) || candidate.code == Int(EPERM)
        {
          return true
        }
        let underlyingError = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        if underlyingError === candidate {
          return false
        }
        currentError = underlyingError
      }
      return false
    }

    func selectFile(suggestedURL: URL) async throws -> URL {
      try await MainActor.run {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = configImportAllowedContentTypes
        panel.directoryURL = suggestedURL.deletingLastPathComponent()
        panel.nameFieldStringValue = suggestedURL.lastPathComponent
        guard panel.runModal() == .OK, let selectedURL = panel.url else {
          throw TunnelDaemonError.usage("config import canceled")
        }
        return selectedURL
      }
    }

    func startAccessingSecurityScope(url: URL) -> Bool {
      url.startAccessingSecurityScopedResource()
    }

    func stopAccessingSecurityScope(url: URL) {
      url.stopAccessingSecurityScopedResource()
    }
  }
#endif

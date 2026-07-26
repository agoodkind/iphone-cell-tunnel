//
//  MacOSConfigImportFileLoaderTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-21.
//  Copyright © 2026, all rights reserved.
//

#if os(macOS)
  @testable import CellTunnelCore
  import Foundation
  import Testing
  import UniformTypeIdentifiers

  struct MacOSConfigImportFileLoaderTests {
    @Test func pickerAcceptsUnknownDataExtension() throws {
      let unknownType = try #require(UTType(filenameExtension: "wg"))

      let isAllowed = configImportAllowedContentTypes.contains { allowedType in
        unknownType.conforms(to: allowedType)
      }

      #expect(isAllowed)
    }

    @Test func permissionDeniedReadUsesScopedPickerSelection() async throws {
      let protectedURL = URL(fileURLWithPath: "/protected/Home.conf")
      let selectedURL = URL(fileURLWithPath: "/selected/Home.conf")
      let expectedFile = ConfigImportFile(name: "Home", text: "[Interface]\n")
      let fileAccess = FakeConfigImportFileAccess(
        protectedURL: protectedURL,
        selectedURL: selectedURL,
        selectedFile: expectedFile
      )
      let loader = MacOSConfigImportFileLoader(fileAccess: fileAccess)

      let file = try await loader.load(path: protectedURL.path)

      #expect(file == expectedFile)
      #expect(
        fileAccess.events == [
          .read(protectedURL),
          .select(protectedURL),
          .startSecurityScope(selectedURL),
          .read(selectedURL),
          .stopSecurityScope(selectedURL),
        ])
    }
  }

  // MARK: - FakeConfigImportFileAccess

  private final class FakeConfigImportFileAccess: ConfigImportFileAccessing,
    @unchecked Sendable
  {
    private(set) var events: [ConfigImportFileAccessEvent] = []
    private let protectedURL: URL
    private let selectedURL: URL
    private let selectedFile: ConfigImportFile

    init(protectedURL: URL, selectedURL: URL, selectedFile: ConfigImportFile) {
      self.protectedURL = protectedURL
      self.selectedURL = selectedURL
      self.selectedFile = selectedFile
    }

    func read(url: URL) throws -> ConfigImportFile {
      events.append(.read(url))
      if url == protectedURL {
        throw ConfigImportFileAccessError.permissionDenied
      }
      return selectedFile
    }

    func isPermissionDenied(_ error: Error) -> Bool {
      guard let accessError = error as? ConfigImportFileAccessError else {
        return false
      }
      return accessError == .permissionDenied
    }

    func selectFile(suggestedURL: URL) async -> URL {
      await Task.yield()
      events.append(.select(suggestedURL))
      return selectedURL
    }

    func startAccessingSecurityScope(url: URL) -> Bool {
      events.append(.startSecurityScope(url))
      return true
    }

    func stopAccessingSecurityScope(url: URL) {
      events.append(.stopSecurityScope(url))
    }
  }

  private enum ConfigImportFileAccessError: Error {
    case permissionDenied
  }

  private enum ConfigImportFileAccessEvent: Equatable {
    case read(URL)
    case select(URL)
    case startSecurityScope(URL)
    case stopSecurityScope(URL)
  }
#endif

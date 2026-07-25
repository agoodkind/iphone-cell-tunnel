//
//  ConfigLibraryPresentationTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-22.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

// MARK: - ConfigLibraryPresentationTests

/// Verifies the Catalyst-only source contract for the config-library presentation model.
/// The app target owns this type, so SwiftPM cannot load it into this package test bundle.
struct ConfigLibraryPresentationTests {
  @Test func stateModelStaysCatalystOnlyAndOwnsEveryDestination() throws {
    let source = try sourceFile(at: "Apps/iOS/Views/ConfigLibraryPresentation.swift")
    let corePresentationPath = repositoryRoot.appending(
      path: "Sources/CellTunnelCore/ConfigLibraryPresentation.swift")

    #expect(source.contains("#if targetEnvironment(macCatalyst)"))
    #expect(!FileManager.default.fileExists(atPath: corePresentationPath.path))
    #expect(source.contains("enum ConfigLibraryPresentation"))
    #expect(source.contains("case creating"))
    #expect(source.contains("case editing(TunnelConfigSummary)"))
    #expect(source.contains("case idle"))
    #expect(source.contains("case importFailure(String)"))
    #expect(source.contains("case importing"))
    #expect(source.contains("case renaming(TunnelConfigSummary)"))
  }

  @Test func stateModelResetsAfterImportAndModalOutcomes() throws {
    let source = try sourceFile(at: "Apps/iOS/Views/ConfigLibraryPresentation.swift")

    #expect(source.contains("mutating func dismissImport()"))
    #expect(source.contains("mutating func completeImportSelection()"))
    #expect(source.contains("mutating func failImport(message: String)"))
    #expect(source.contains("mutating func dismiss()"))
    #expect(source.contains("self = .idle"))
  }

  @Test func viewUsesOneStateAndDerivedPresentationBindings() throws {
    let source = try sourceFile(at: "Apps/iOS/Views/ConfigLibraryView.swift")

    #expect(source.contains("@State private var presentation = ConfigLibraryPresentation.idle"))
    #expect(!source.contains("isImportingConfig"))
    #expect(!source.contains("isCreatingConfig"))
    #expect(!source.contains("editingConfig"))
    #expect(!source.contains("isRenaming"))
    #expect(!source.contains("renamingID"))
    #expect(source.contains("private var editorPresentationBinding"))
    #expect(source.contains("private var importPresentationBinding"))
    #expect(source.contains("private var alertPresentationBinding"))
    #expect(source.contains(".sheet(item: editorPresentationBinding)"))
    #expect(source.contains(".alert("))
    #expect(source.contains(".fileImporter("))
    #expect(source.contains("presentation.completeImportSelection()"))
    #expect(source.contains("presentation.failImport(message: error.localizedDescription)"))
  }
}

// MARK: - Source fixture

private let repositoryRoot = URL(filePath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()

private func sourceFile(at path: String) throws -> String {
  try String(contentsOf: repositoryRoot.appending(path: path), encoding: .utf8)
}

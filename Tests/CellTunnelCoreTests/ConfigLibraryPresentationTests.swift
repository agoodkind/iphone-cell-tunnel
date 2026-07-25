//
//  ConfigLibraryPresentationTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-22.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCatalystPresentation
import CellTunnelCore
import Foundation
import Testing

// MARK: - ConfigLibraryPresentationTests

/// Exercises the state machine that owns every Catalyst config-library destination. The
/// package compiles the Catalyst-only source through its test-only target, leaving the
/// iPhone and shared core targets free of config-library presentation code.
struct ConfigLibraryPresentationTests {
  private let config = TunnelConfigSummary(
    id: UUID(),
    name: "Home",
    createdAt: Date(timeIntervalSince1970: 1_721_000_000)
  )

  // MARK: - Exclusivity

  @Test func destinationsReplaceThePreviousPresentation() {
    var presentation = ConfigLibraryPresentation.idle

    presentation.presentImport()
    presentation.presentCreate()
    #expect(presentation == .creating)

    presentation.presentEdit(config)
    #expect(presentation == .editing(config))

    presentation.presentRename(config)
    #expect(presentation == .renaming(config))
  }

  // MARK: - Import

  @Test func repeatedImportCancellationCyclesRestoreIdle() {
    var presentation = ConfigLibraryPresentation.idle

    for _ in 0..<2 {
      presentation.presentImport()
      #expect(presentation == .importing)

      presentation.dismissImport()
      #expect(presentation == .idle)
    }
  }

  @Test func successfulImportSelectionRestoresIdle() {
    var presentation = ConfigLibraryPresentation.idle

    presentation.presentImport()
    presentation.completeImport(.success(()))

    #expect(presentation == .idle)
  }

  @Test func importFailureReplacesTheImporterWithAnAlert() {
    var presentation = ConfigLibraryPresentation.idle

    presentation.presentImport()
    presentation.completeImport(.failure(PresentationImportError()))

    #expect(presentation == .importFailure(PresentationImportError.message))

    presentation.dismiss()
    #expect(presentation == .idle)
  }

  // MARK: - Editor

  @Test func editorDismissalRestoresIdleForCreateAndEdit() {
    var presentation = ConfigLibraryPresentation.idle

    presentation.presentCreate()
    presentation.dismiss()
    #expect(presentation == .idle)

    presentation.presentEdit(config)
    presentation.dismiss()
    #expect(presentation == .idle)
  }

  // MARK: - Rename

  @Test func renameDismissalRestoresIdle() {
    var presentation = ConfigLibraryPresentation.idle

    presentation.presentRename(config)
    presentation.dismiss()

    #expect(presentation == .idle)
  }
}

// MARK: - PresentationImportError

private struct PresentationImportError: LocalizedError {
  static let message = "The selected config could not be imported."

  var errorDescription: String? {
    Self.message
  }
}

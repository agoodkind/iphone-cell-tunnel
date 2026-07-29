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

  /// An alert built from the description alone names what failed and leaves the reader
  /// with no next step, so the recovery has to reach the alert with it.
  @Test func importFailureAlertNamesTheCauseAndTheRecovery() {
    var presentation = ConfigLibraryPresentation.idle

    presentation.presentImport()
    presentation.completeImport(
      .failure(TunnelConfigStoreError.keychainFailure(keychainInteractionNotAllowed)))

    #expect(
      presentation
        == .importFailure(
          "Cell Tunnel couldn’t save the configuration to your keychain, "
            + "user interaction may not be allowed. "
            + "Unlock your login keychain, then import the configuration again."))
  }

  /// The message reaches the app through the agent, which sends a string rather than a
  /// typed error, so the recovery has to be in that string before it leaves the agent.
  @Test func theComposedMessageIsWhatTravelsToTheApp() {
    let message = userFacingMessage(
      for: TunnelConfigStoreError.keychainFailure(keychainInteractionNotAllowed))

    #expect(message.contains("Unlock your login keychain"))
    #expect(!message.contains("store config failed"))
    #expect(!message.contains("\(keychainInteractionNotAllowed)"))
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

// MARK: - Keychain status

/// `errSecInteractionNotAllowed`, the refusal a locked keychain produces, written as a
/// literal so the test does not depend on which module re-exports the constant.
private let keychainInteractionNotAllowed: OSStatus = -25_308

// MARK: - PresentationImportError

private struct PresentationImportError: LocalizedError {
  static let message = "The selected config could not be imported."

  var errorDescription: String? {
    Self.message
  }
}

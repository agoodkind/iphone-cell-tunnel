//
//  ConfigLibraryPresentation.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-22.
//  Copyright © 2026, all rights reserved.
//

#if targetEnvironment(macCatalyst) || CATALYST_PRESENTATION_TESTING
  import CellTunnelCore
  import Foundation

  // MARK: - ConfigLibraryPresentation

  /// The one destination the Catalyst config library can present. Replacing this value
  /// dismisses the previous destination, which prevents an invisible importer, sheet, or
  /// alert from blocking the library behind the visible presentation.
  public enum ConfigLibraryPresentation: Equatable, Identifiable, Sendable {
    case creating
    case editing(TunnelConfigSummary)
    case idle
    case importFailure(String)
    case importing
    case renaming(TunnelConfigSummary)

    /// A stable identity for SwiftUI's item-based sheet and alert presentation.
    public var id: String {
      switch self {
      case .creating:
        "creating"
      case .editing(let config):
        "editing-\(config.id.uuidString)"
      case .idle:
        "idle"
      case .importFailure(let message):
        "import-failure-\(message)"
      case .importing:
        "importing"
      case .renaming(let config):
        "renaming-\(config.id.uuidString)"
      }
    }

    /// Whether SwiftUI should show the document importer.
    public var isImporting: Bool {
      self == .importing
    }

    /// The editor presentation, if the current destination is a create or edit sheet.
    public var editorPresentation: ConfigLibraryPresentation? {
      switch self {
      case .creating, .editing:
        self
      case .idle, .importFailure, .importing, .renaming:
        nil
      }
    }

    /// The alert presentation, if the current destination is a rename or import error.
    public var alertPresentation: ConfigLibraryPresentation? {
      switch self {
      case .importFailure, .renaming:
        self
      case .creating, .editing, .idle, .importing:
        nil
      }
    }

    /// Starts the document import presentation.
    public mutating func presentImport() {
      self = .importing
    }

    /// Starts the new-config editor presentation.
    public mutating func presentCreate() {
      self = .creating
    }

    /// Starts the existing-config editor presentation.
    public mutating func presentEdit(_ config: TunnelConfigSummary) {
      self = .editing(config)
    }

    /// Starts the rename alert presentation.
    public mutating func presentRename(_ config: TunnelConfigSummary) {
      self = .renaming(config)
    }

    /// Ends the active document import after the user cancels it.
    public mutating func dismissImport() {
      guard isImporting else {
        return
      }
      self = .idle
    }

    /// Ends the document import before its selected file is handed to the agent.
    public mutating func completeImportSelection() {
      dismissImport()
    }

    /// Shows an error from a selected file only when no newer presentation replaced it.
    public mutating func completeImportFailure(message: String) {
      guard self == .idle else {
        return
      }
      self = .importFailure(message)
    }

    /// Replaces the document importer with an error alert when importing cannot complete.
    public mutating func completeImport(_ result: Result<Void, Error>) {
      switch result {
      case .success:
        dismissImport()
      case .failure(let error):
        failImport(message: error.localizedDescription)
      }
    }

    /// Replaces the document importer with an error alert when the picker fails.
    public mutating func failImport(message: String) {
      self = .importFailure(message)
    }

    /// Ends the active sheet or alert.
    public mutating func dismiss() {
      self = .idle
    }
  }

#endif

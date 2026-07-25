//
//  ConfigLibraryCapabilityBoundaryTests.swift
//  CellTunnelCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-21.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

// MARK: - ConfigLibraryCapabilityBoundaryTests

struct ConfigLibraryCapabilityBoundaryTests {
  @Test func configManagementIsCatalystOnly() throws {
    let relayBackend = try sourceFile(at: "Apps/iOS/Services/RelayControlBackend.swift")
    let relayProtocol = try sourceBetween(
      relayBackend,
      start: "protocol RelayControlBackend {",
      end: "// MARK: - Defaults"
    )
    let configBackend = try sourceFile(at: "Apps/iOS/Services/ConfigLibraryBackend.swift")
    let controllerConfigActions = try sourceFile(
      at: "Apps/iOS/Services/RelayController+ConfigLibrary.swift")
    let agentBackend = try sourceFile(at: "Apps/iOS/Services/AgentRelayBackend.swift")
    let installationState = try sourceFile(at: "Apps/iOS/Services/InstallationState.swift")
    let configDefaultsPath =
      repositoryRoot
      .appending(path: "Apps/iOS/Services/RelayControlBackend+ConfigDefaults.swift")

    #expect(!relayProtocol.contains("tunnelProvisioned"))
    #expect(!relayProtocol.contains("installTunnel"))
    #expect(!relayProtocol.contains("Config"))
    #expect(configBackend.contains("#if targetEnvironment(macCatalyst)"))
    #expect(configBackend.contains("protocol ConfigLibraryBackend"))
    #expect(!configBackend.contains("tunnelProvisioned"))
    #expect(configBackend.contains("func installTunnel(configURL: URL) async"))
    #expect(configBackend.contains("func loadConfigText(id: UUID) async -> String?"))
    #expect(configBackend.contains("func importConfig(url: URL, name: String) async"))
    #expect(configBackend.contains("func importConfig(name: String, text: String) async"))
    #expect(configBackend.contains("func activateConfig(id: UUID) async"))
    #expect(configBackend.contains("func saveConfigEdit(id: UUID, text: String) async"))
    #expect(configBackend.contains("func deleteConfig(id: UUID) async"))
    #expect(configBackend.contains("func renameConfig(id: UUID, name: String) async"))
    #expect(controllerConfigActions.contains("#if targetEnvironment(macCatalyst)"))
    #expect(controllerConfigActions.contains("func installTunnel(configURL: URL) async"))
    #expect(controllerConfigActions.contains("func loadConfigText(id: UUID) async -> String?"))
    #expect(controllerConfigActions.contains("func importConfig(url: URL, name: String)"))
    #expect(controllerConfigActions.contains("func createConfig(name: String, text: String)"))
    #expect(controllerConfigActions.contains("func activateConfig(id: UUID)"))
    #expect(controllerConfigActions.contains("func saveConfigEdit(id: UUID, text: String)"))
    #expect(controllerConfigActions.contains("func deleteConfig(id: UUID)"))
    #expect(controllerConfigActions.contains("func renameConfig(id: UUID, name: String)"))
    #expect(agentBackend.contains("AgentRelayBackend: RelayControlBackend, ConfigLibraryBackend"))
    #expect(!agentBackend.contains("func tunnelProvisioned"))
    #expect(!FileManager.default.fileExists(atPath: configDefaultsPath.path))
    let guardedInstallationState =
      installationState
      .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(guardedInstallationState.contains("#if targetEnvironment(macCatalyst)"))
    #expect(!guardedInstallationState.contains("\n#else\n"))
    #expect(guardedInstallationState.hasSuffix("#endif"))
  }

  @Test func iPhoneRetainsApprovalWithoutConfigLibraryOperations() throws {
    let contentView = try sourceFile(at: "Apps/iOS/Views/PhoneContentView.swift")
    let enableTunnelScreen = try sourceFile(at: "Apps/iOS/Views/EnableTunnelScreen.swift")
    let screenModel = try sourceFile(at: "Apps/iOS/Views/RelayScreenModel.swift")
    let phoneBackend = try sourceFile(at: "Apps/iOS/Services/PhoneRelayBackend.swift")
    let simulatorBackend = try sourceFile(at: "Apps/iOS/Services/SimulatorRelayBackend.swift")
    let previewBackend = try sourceFile(at: "Apps/iOS/Views/PreviewRelayBackend.swift")
    let phonePreviewBackend = try sourceBetween(
      previewBackend,
      start: "#else\n  extension PreviewRelayBackend: PhoneTunnelProvisioningBackend",
      end: "#endif"
    )

    #expect(contentView.contains("EnableTunnelScreen()"))
    #expect(enableTunnelScreen.contains("model.startSession()"))
    #expect(screenModel.contains("func startSession()"))
    #expect(screenModel.contains("Task { await controller.start() }"))
    #expect(screenModel.contains("Task { await controller.setRouteTraffic(enabled: newValue) }"))
    #expect(phoneBackend.contains("try await loadOrCreateManager()"))
    #expect(phoneBackend.contains("try startSessionIfNeeded(on: loadedManager)"))

    for backend in [phoneBackend, simulatorBackend, phonePreviewBackend] {
      #expect(!backend.contains("ConfigLibraryBackend"))
      #expect(!backend.contains("func installTunnel"))
      #expect(!backend.contains("func loadConfigText"))
      #expect(!backend.contains("func importConfig"))
      #expect(!backend.contains("func createConfig"))
      #expect(!backend.contains("func activateConfig"))
      #expect(!backend.contains("func saveConfigEdit"))
      #expect(!backend.contains("func deleteConfig"))
      #expect(!backend.contains("func renameConfig"))
    }
  }

  @Test func selectedConfigImportErrorsReachTheCatalystPresentation() throws {
    let configBackend = try sourceFile(at: "Apps/iOS/Services/ConfigLibraryBackend.swift")
    let agentBackend = try sourceFile(at: "Apps/iOS/Services/AgentRelayBackend.swift")
    let controllerActions = try sourceFile(
      at: "Apps/iOS/Services/RelayController+ConfigLibrary.swift")
    let configLibraryView = try sourceFile(at: "Apps/iOS/Views/ConfigLibraryView.swift")

    #expect(configBackend.contains("func importConfig(url: URL, name: String) async throws"))
    #expect(agentBackend.contains("func importConfig(url: URL, name: String) async throws"))
    #expect(agentBackend.contains("func importConfig(name: String, text: String) async throws"))
    #expect(controllerActions.contains("func importConfig(url: URL, name: String) async throws"))
    #expect(
      configLibraryView.contains("try await controller.importConfig(url: url, name: name)")
    )
    #expect(
      configLibraryView.contains(
        "presentation.completeImportFailure(message: error.localizedDescription)")
    )
  }

  @Test func catalystPresentationTestTargetUsesItsOwnProductionDirectory() throws {
    let package = try sourceFile(at: "Package.swift")
    let presentationPath = repositoryRoot.appending(
      path: "Apps/iOS/Presentation/ConfigLibraryPresentation.swift")
    let legacyPresentationPath = repositoryRoot.appending(
      path: "Apps/iOS/Views/ConfigLibraryPresentation.swift")

    #expect(package.contains("path: \"Apps/iOS/Presentation\""))
    #expect(!package.contains("path: \"Apps/iOS/Views\""))
    #expect(FileManager.default.fileExists(atPath: presentationPath.path))
    #expect(!FileManager.default.fileExists(atPath: legacyPresentationPath.path))
  }
}

// MARK: - Source fixtures

private let repositoryRoot = URL(filePath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()

private func sourceFile(at path: String) throws -> String {
  try String(contentsOf: repositoryRoot.appending(path: path), encoding: .utf8)
}

private func sourceBetween(_ source: String, start: String, end: String) throws -> String {
  guard let startRange = source.range(of: start) else {
    throw SourceFixtureError.markerMissing(start)
  }
  guard let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
    throw SourceFixtureError.markerMissing(end)
  }
  return String(source[startRange.lowerBound..<endRange.lowerBound])
}

// MARK: - SourceFixtureError

private enum SourceFixtureError: Error {
  case markerMissing(String)
}

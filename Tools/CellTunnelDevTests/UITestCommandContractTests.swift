//
//  UITestCommandContractTests.swift
//  CellTunnelDevTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-22.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing
@testable import CellTunnelDev

// MARK: - UITestCommandContractTests

struct UITestCommandContractTests {
  // MARK: - Project

  @Test func projectDefinesOneCrossPlatformPhoneUITestTarget() throws {
    let project = try sourceFile(at: "Project.swift")

    #expect(project.contains("name: \"CellTunnelPhoneUITests\""))
    #expect(project.contains("destinations: [.iPhone, .macCatalyst]"))
    #expect(project.contains("product: .uiTests"))
    #expect(project.contains(".target(name: \"CellTunnelPhone\")"))
  }

  // MARK: - Command

  @Test func developmentToolExposesCrossPlatformUITestCommand() throws {
    let main = try sourceFile(at: "Tools/CellTunnelDev/main.swift")
    let command = try sourceFile(at: "Tools/CellTunnelDev/UITestActions.swift")

    #expect(main.contains("case \"ui-test\":"))
    #expect(command.contains("enum UITestTarget"))
    #expect(command.contains("case iphoneSimulator = \"iphone-simulator\""))
    #expect(command.contains("case macCatalyst = \"mac-catalyst\""))
    #expect(command.contains("selectedPhoneSimulatorIdentifier()"))
    #expect(command.contains("bootPhoneSimulator(identifier: simulatorIdentifier)"))
    #expect(command.contains("uiTestSimulatorDestination(identifier: simulatorIdentifier)"))
    #expect(command.contains("generator: .xcodegen"))
    #expect(command.contains("project: \"CellTunnel.xcodeproj\""))
  }

  @Test func simulatorUITestDestinationUsesTheResolvedUDID() {
    #expect(
      uiTestSimulatorDestination(identifier: "fixture-simulator")
        == "platform=iOS Simulator,id=fixture-simulator"
    )
  }

  // MARK: - Fixture boundary

  @Test func debugFixtureAndAccessibilityIdentifiersHaveStrictBoundaries() throws {
    let fixture = try sourceFile(at: "Apps/iOS/Testing/UITestFixture.swift")
    let identifiers = try sourceFile(
      at: "Apps/iOS/Accessibility/CellTunnelAccessibilityIdentifier.swift")
    let uiTests = try sourceFile(at: "Tests/CellTunnelPhoneUITests/CellTunnelPhoneUITests.swift")

    #expect(fixture.contains("#if DEBUG"))
    #expect(fixture.contains("CELL_TUNNEL_UI_TEST_APPROVAL_REQUIRED"))
    #expect(!fixture.contains("AgentClient"))
    #expect(!fixture.contains("ServiceManagement"))
    #expect(!fixture.contains("cellTunnelAppGroupIdentifier"))
    #expect(!fixture.contains("DeviceEgressProbe()"))
    for identifier in [
      "cell-tunnel.route-traffic",
      "cell-tunnel.vpn-approval",
      "cell-tunnel.import-config",
      "cell-tunnel.new-config",
      "cell-tunnel.config-actions",
      "cell-tunnel.edit-config",
      "cell-tunnel.rename-config",
      "cell-tunnel.delete-config",
      "cell-tunnel.config-editor",
      "cell-tunnel.mac-status-scroll",
      "cell-tunnel.fixture-scroll-recovery",
    ] {
      #expect(identifiers.contains(identifier))
    }
    #expect(uiTests.contains("try assertStatusScrolls()"))
    #expect(uiTests.contains("scrollRecoverySwipeCount"))
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

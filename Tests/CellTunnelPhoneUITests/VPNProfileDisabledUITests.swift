//
//  VPNProfileDisabledUITests.swift
//  CellTunnelPhoneUITests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import XCTest

// MARK: - Constants

private let vpnDisabledFixtureArgument = "--cell-tunnel-ui-test-vpn-disabled"
private let setupActionIdentifier = "cell-tunnel.setup-action"
private let setupStepsIdentifier = "cell-tunnel.setup-steps"
private let routeTrafficIdentifier = "cell-tunnel.route-traffic"
private let openSettingsTitle = "Open System Settings"
private let turnOnStepText = "Turn on Cell Tunnel."
private let elementWaitTimeout: TimeInterval = 8

// MARK: - VPNProfileDisabledUITests

/// Covers the screen the Mac shows when the saved VPN profile is switched off. The
/// fixture supplies a dialed-in peer and an active configuration, so every input
/// routing needs is present and the switched-off profile is the only thing
/// withholding it.
@MainActor
final class VPNProfileDisabledUITests: XCTestCase {
  #if targetEnvironment(macCatalyst)
    /// A profile the user switched off cannot carry traffic, so the screen offers to
    /// take them to System Settings, shows what to do once there, and presents no
    /// routing switch that could not take effect.
    func testDisabledProfileOffersReEnableWithStepsAndNoRoutingSwitch() throws {
      let app = launchFixture()
      let setupButton = app.buttons[setupActionIdentifier]
      try require(setupButton.waitForExistence(timeout: elementWaitTimeout))

      try require(setupButton.label == openSettingsTitle, app.debugDescription)
      let steps = app.otherElements[setupStepsIdentifier]
      try require(steps.waitForExistence(timeout: elementWaitTimeout), app.debugDescription)
      try require(app.staticTexts[turnOnStepText].exists, app.debugDescription)
      try require(!app.switches[routeTrafficIdentifier].exists, app.debugDescription)
    }

    // MARK: - Helpers

    private func launchFixture() -> XCUIApplication {
      let application = XCUIApplication()
      application.launchArguments += [vpnDisabledFixtureArgument]
      application.launch()
      return application
    }

    private func require(
      _ condition: @autoclosure () -> Bool,
      _ message: String = ""
    ) throws {
      guard condition() else {
        throw VPNProfileDisabledFailure(message: message)
      }
    }
  #endif
}

// MARK: - VPNProfileDisabledFailure

#if targetEnvironment(macCatalyst)
  private struct VPNProfileDisabledFailure: Error, LocalizedError {
    let message: String

    var errorDescription: String? {
      if message.isEmpty {
        return "vpn profile disabled ui test condition not met"
      }
      return message
    }
  }
#endif

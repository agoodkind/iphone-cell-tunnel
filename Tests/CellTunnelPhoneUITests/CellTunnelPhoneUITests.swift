//
//  CellTunnelPhoneUITests.swift
//  CellTunnelPhoneUITests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-22.
//  Copyright © 2026, all rights reserved.
//

import XCTest

// MARK: - Constants

private let fixtureArgument = "--cell-tunnel-ui-test-fixture"
private let routeTrafficIdentifier = "cell-tunnel.route-traffic"
private let importConfigIdentifier = "cell-tunnel.import-config"
private let newConfigIdentifier = "cell-tunnel.new-config"
private let configActionsIdentifier = "cell-tunnel.config-actions"
private let editConfigIdentifier = "cell-tunnel.edit-config"
private let renameConfigIdentifier = "cell-tunnel.rename-config"
private let deleteConfigIdentifier = "cell-tunnel.delete-config"
private let configEditorIdentifier = "cell-tunnel.config-editor"
private let elementWaitTimeout: TimeInterval = 8

// MARK: - CellTunnelPhoneUITests

@MainActor
final class CellTunnelPhoneUITests: XCTestCase {
  private var testApplication: XCUIApplication?

  private var app: XCUIApplication {
    testApplication ?? XCUIApplication()
  }

  // MARK: - iPhone

  #if !targetEnvironment(macCatalyst)
    func testIPhoneShowsOnlyProvisionedRouteTrafficControl() throws {
      launch(arguments: [fixtureArgument])

      try require(
        app.switches[routeTrafficIdentifier].waitForExistence(timeout: elementWaitTimeout))
      try assertConfigurationControlsAreAbsent()
    }
  #endif

  // MARK: - Mac Catalyst

  #if targetEnvironment(macCatalyst)
    func testCatalystNewOpensAndDismissesTheConfigEditor() throws {
      launch(arguments: [fixtureArgument])
      let newButton = app.buttons[newConfigIdentifier]
      try require(newButton.waitForExistence(timeout: elementWaitTimeout))

      newButton.tap()
      let editor = app.otherElements[configEditorIdentifier]
      try require(editor.waitForExistence(timeout: elementWaitTimeout))
      app.buttons["Cancel"].tap()
      try assertElementDisappears(editor)
    }
  #endif

  // MARK: - Launch and assertions

  private func launch(arguments: [String]) {
    continueAfterFailure = false
    let application = XCUIApplication()
    application.launchArguments = arguments
    application.launch()
    testApplication = application
  }

  private func assertConfigurationControlsAreAbsent() throws {
    for identifier in [
      importConfigIdentifier,
      newConfigIdentifier,
      editConfigIdentifier,
      renameConfigIdentifier,
      deleteConfigIdentifier,
      configEditorIdentifier,
    ] {
      try require(!app.descendants(matching: .any)[identifier].exists)
    }
    let configActions = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", configActionsIdentifier)
    )
    try require(configActions.count == 0)
  }

  private func assertElementDisappears(_ element: XCUIElement) throws {
    let predicate = NSPredicate(format: "exists == false")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    let result = XCTWaiter().wait(for: [expectation], timeout: elementWaitTimeout)
    try require(result == .completed)
  }

  private func require(_ condition: @autoclosure () -> Bool) throws {
    guard condition() else {
      throw UITestFailure()
    }
  }
}

// MARK: - UITestFailure

private struct UITestFailure: Error {}

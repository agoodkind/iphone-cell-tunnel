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
private let approvalRequiredArgument = "--cell-tunnel-ui-test-approval-required"
private let approvalRequiredEnvironment = "CELL_TUNNEL_UI_TEST_APPROVAL_REQUIRED"
private let routeTrafficIdentifier = "cell-tunnel.route-traffic"
private let vpnApprovalIdentifier = "cell-tunnel.vpn-approval"
private let importConfigIdentifier = "cell-tunnel.import-config"
private let newConfigIdentifier = "cell-tunnel.new-config"
private let configActionsIdentifier = "cell-tunnel.config-actions"
private let editConfigIdentifier = "cell-tunnel.edit-config"
private let renameConfigIdentifier = "cell-tunnel.rename-config"
private let deleteConfigIdentifier = "cell-tunnel.delete-config"
private let configEditorIdentifier = "cell-tunnel.config-editor"
private let macStatusScrollIdentifier = "cell-tunnel.mac-status-scroll"
private let fixtureScrollRecoveryMarkerIdentifier = "cell-tunnel.fixture-scroll-recovery"
private let pickerServiceBundleIdentifier = "com.apple.appkit.xpc.openAndSavePanelService"
private let elementWaitTimeout: TimeInterval = 8
private let scrollRecoverySwipeCount = 3

// MARK: - CellTunnelPhoneUITests

@MainActor
final class CellTunnelPhoneUITests: XCTestCase {
  private var testApplication: XCUIApplication?

  private var app: XCUIApplication {
    testApplication ?? XCUIApplication()
  }

  // MARK: - iPhone

  #if !targetEnvironment(macCatalyst)
    func testIPhoneOffersOneTimeVPNApprovalWhenFixtureRequiresIt() throws {
      launch(
        arguments: [fixtureArgument, approvalRequiredArgument],
        environment: [approvalRequiredEnvironment: "1"]
      )

      try require(
        app.buttons[vpnApprovalIdentifier].waitForExistence(timeout: elementWaitTimeout),
        app.debugDescription
      )
      try assertConfigurationControlsAreAbsent()
    }

    func testIPhoneShowsOnlyProvisionedRouteTrafficControl() throws {
      launch(arguments: [fixtureArgument])

      try require(
        app.switches[routeTrafficIdentifier].waitForExistence(timeout: elementWaitTimeout))
      try assertConfigurationControlsAreAbsent()
    }
  #endif

  // MARK: - Mac Catalyst

  #if targetEnvironment(macCatalyst)
    func testCatalystImportCancelRestoresInteractionAndScrollsStatus() throws {
      launch(arguments: [fixtureArgument])
      let importButton = app.buttons[importConfigIdentifier]
      try require(importButton.waitForExistence(timeout: elementWaitTimeout))

      importButton.tap()
      let picker = try pickerPresentationAfterImport()
      try cancelPicker(picker)

      try assertRestoredStatusInteraction()
      try assertStatusScrolls()
    }

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

    func testCatalystEscapeFromImportRestoresStatusInteraction() throws {
      launch(arguments: [fixtureArgument])
      let importButton = app.buttons[importConfigIdentifier]
      try require(importButton.waitForExistence(timeout: elementWaitTimeout))

      importButton.tap()
      let picker = try pickerPresentationAfterImport()
      picker.host.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

      try assertPickerDismissed(picker)
      try assertRestoredStatusInteraction()
      try assertStatusScrolls()
    }

    func testCatalystRepeatedImportCancellationLeavesNoModalShield() throws {
      launch(arguments: [fixtureArgument])
      let importButton = app.buttons[importConfigIdentifier]
      try require(importButton.waitForExistence(timeout: elementWaitTimeout))

      for _ in 0..<5 {
        importButton.tap()
        let picker = try pickerPresentationAfterImport()
        try cancelPicker(picker)
        try assertRestoredStatusInteraction()
      }

      let newButton = app.buttons[newConfigIdentifier]
      try require(newButton.isHittable)
    }
  #endif

  // MARK: - Launch and assertions

  private func launch(arguments: [String], environment: [String: String] = [:]) {
    continueAfterFailure = false
    let application = XCUIApplication()
    application.launchArguments = arguments
    application.launchEnvironment = environment
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
    try require(!configActions.firstMatch.exists)
  }

  // MARK: - Picker

  #if targetEnvironment(macCatalyst)
    private func pickerPresentationAfterImport() throws -> PickerPresentation {
      let sheet = app.sheets.firstMatch
      if sheet.waitForExistence(timeout: elementWaitTimeout) {
        return PickerPresentation(host: app, element: sheet)
      }
      let dialog = app.dialogs.firstMatch
      if dialog.waitForExistence(timeout: elementWaitTimeout) {
        return PickerPresentation(host: app, element: dialog)
      }

      let service = XCUIApplication(bundleIdentifier: pickerServiceBundleIdentifier)
      let window = service.windows.firstMatch
      try require(window.waitForExistence(timeout: elementWaitTimeout))
      return PickerPresentation(host: service, element: window)
    }

    private func cancelPicker(_ picker: PickerPresentation) throws {
      let cancel = picker.host.buttons["Cancel"]
      try require(cancel.waitForExistence(timeout: elementWaitTimeout))
      cancel.tap()
      try assertPickerDismissed(picker)
    }

    private func assertPickerDismissed(_ picker: PickerPresentation) throws {
      try assertElementDisappears(picker.element)
    }

    private func assertRestoredStatusInteraction() throws {
      let importButton = app.buttons[importConfigIdentifier]
      let newButton = app.buttons[newConfigIdentifier]
      let scrollView = app.scrollViews[macStatusScrollIdentifier]
      try require(importButton.waitForExistence(timeout: elementWaitTimeout))
      try require(newButton.waitForExistence(timeout: elementWaitTimeout))
      try require(scrollView.waitForExistence(timeout: elementWaitTimeout))
      try require(importButton.isHittable)
      try require(newButton.isHittable)
      try require(scrollView.isHittable)
    }

    private func assertStatusScrolls() throws {
      let scrollView = app.scrollViews[macStatusScrollIdentifier]
      let marker = app.staticTexts[fixtureScrollRecoveryMarkerIdentifier]
      try require(marker.waitForExistence(timeout: elementWaitTimeout))
      try require(!marker.isHittable)

      for _ in 0..<scrollRecoverySwipeCount {
        scrollView.swipeUp()
      }
      try assertElementBecomesHittable(marker)
    }
  #endif

  // MARK: - Waiting

  private func assertElementDisappears(_ element: XCUIElement) throws {
    let predicate = NSPredicate(format: "exists == false")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    let result = XCTWaiter().wait(for: [expectation], timeout: elementWaitTimeout)
    try require(result == .completed)
  }

  private func assertElementBecomesHittable(_ element: XCUIElement) throws {
    let predicate = NSPredicate(format: "isHittable == true")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    let result = XCTWaiter().wait(for: [expectation], timeout: elementWaitTimeout)
    try require(result == .completed)
  }

  private func require(_ condition: @autoclosure () -> Bool, _ message: String = "") throws {
    guard condition() else {
      throw UITestFailure(message: message)
    }
  }
}

// MARK: - PickerPresentation

#if targetEnvironment(macCatalyst)
  private struct PickerPresentation {
    let host: XCUIApplication
    let element: XCUIElement
  }
#endif

// MARK: - UITestFailure

private struct UITestFailure: Error, LocalizedError {
  let message: String

  var errorDescription: String? {
    message
  }
}

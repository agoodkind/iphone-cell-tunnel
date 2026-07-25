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
private let notificationCenterBundleIdentifier = "com.apple.UserNotificationCenter"
private let elementWaitTimeout: TimeInterval = 8
private let scrollRecoverySwipeCount = 3
private let windowResizeTolerance: CGFloat = 2
private let catalystWindowBorderThickness: CGFloat = 1
private let catalystWindowTitleBarHeight: CGFloat = 32
private let windowMinimumContentWidth: CGFloat = 600
private let windowMinimumContentHeight: CGFloat = 420
private let windowDefaultContentWidth: CGFloat = 760
private let windowDefaultContentHeight: CGFloat = 520
private let windowMinimumFrame = CGSize(
  width: windowMinimumContentWidth + catalystWindowBorderThickness,
  height: windowMinimumContentHeight
    + catalystWindowTitleBarHeight
    + catalystWindowBorderThickness
)
private let windowDefaultFrame = CGSize(
  width: windowDefaultContentWidth,
  height: windowDefaultContentHeight + catalystWindowTitleBarHeight
)
private let savedDraftMarker = "# Cell Tunnel saved draft marker"
private let canceledDraftMarker = "# Cell Tunnel canceled draft marker"
private let overflowLine = "# Cell Tunnel overflow line\n"
private let overflowLineCount = 80
private let windowMenuTitle = "Window"
private let fillWindowTitle = "Fill"
private let moveAndResizeTitle = "Move & Resize"
private let quartersActionIdentifier = "_zoomQuarters:"
private let bottomRightTitle = "Bottom Right"

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
      let identifiedSwitches = app.switches.matching(
        NSPredicate(format: "identifier != ''")
      )
      try require(identifiedSwitches.count == 1, app.debugDescription)
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

    func testCatalystWindowGrowsFromItsDefaultSize() throws {
      launch(arguments: [fixtureArgument])
      let parentWindow = app.windows.firstMatch
      try require(parentWindow.waitForExistence(timeout: elementWaitTimeout), app.debugDescription)
      let content = app.scrollViews[macStatusScrollIdentifier]
      try require(content.waitForExistence(timeout: elementWaitTimeout), app.debugDescription)
      try dismissUserNotificationDialogIfPresented()
      _ = try waitForFrame(of: parentWindow) { frame in
        abs(frame.width - windowDefaultFrame.width) <= windowResizeTolerance
          && abs(frame.height - windowDefaultFrame.height) <= windowResizeTolerance
      }

      try shrinkToMinimum()
      _ = try waitForFrame(of: parentWindow) { frame in
        abs(frame.width - windowMinimumFrame.width) <= windowResizeTolerance
          && abs(frame.height - windowMinimumFrame.height) <= windowResizeTolerance
      }

      try grow()
      _ = try waitForFrame(of: parentWindow) { frame in
        frame.width > windowMinimumFrame.width + windowResizeTolerance
          && frame.height > windowMinimumFrame.height + windowResizeTolerance
      }
    }

    func testCatalystNewEditorAndDraftGrowTogether() throws {
      launch(arguments: [fixtureArgument])
      let newButton = app.buttons[newConfigIdentifier]
      try require(newButton.waitForExistence(timeout: elementWaitTimeout))
      let parentWindow = app.windows.firstMatch
      try require(parentWindow.waitForExistence(timeout: elementWaitTimeout), app.debugDescription)
      try shrinkToMinimum()
      newButton.tap()

      let fields = try editorFields()
      let editor = fields.editor
      let draft = fields.draft
      let initialParentFrame = parentWindow.frame
      let initialEditorFrame = editor.frame
      let initialDraftFrame = draft.frame
      draft.tap()
      let overflowDraft = String(repeating: overflowLine, count: overflowLineCount)
      draft.typeText("\n\(overflowDraft)\(savedDraftMarker)")
      try require(draftContains(draft, marker: savedDraftMarker), app.debugDescription)

      try grow()

      _ = try waitForFrame(of: parentWindow) { frame in
        frame.width > initialParentFrame.width + windowResizeTolerance
          && frame.height > initialParentFrame.height + windowResizeTolerance
      }
      let postFillEditorFrame = try waitForFrame(of: editor) { frame in
        frame.width > initialEditorFrame.width + windowResizeTolerance
          && frame.height > initialEditorFrame.height + windowResizeTolerance
      }
      let postFillDraftFrame = try waitForFrame(of: draft) { frame in
        frame.width > initialDraftFrame.width + windowResizeTolerance
          && frame.height > initialDraftFrame.height + windowResizeTolerance
      }
      try shrinkToMinimum()
      _ = try waitForFrame(of: editor) { frame in
        frame.width < postFillEditorFrame.width - windowResizeTolerance
          && frame.height < postFillEditorFrame.height - windowResizeTolerance
      }
      _ = try waitForFrame(of: draft) { frame in
        frame.width < postFillDraftFrame.width - windowResizeTolerance
          && frame.height < postFillDraftFrame.height - windowResizeTolerance
      }
      try require(draftContains(draft, marker: savedDraftMarker), app.debugDescription)
      let beforeScroll = draft.screenshot()
      addScreenshot(beforeScroll, named: "draft-before-scroll")
      app.typeKey(XCUIKeyboardKey.pageUp, modifierFlags: [])
      let afterScroll = draft.screenshot()
      addScreenshot(afterScroll, named: "draft-after-scroll")
      try require(
        beforeScroll.pngRepresentation != afterScroll.pngRepresentation,
        "draft did not visibly scroll"
      )
      editor.buttons["Cancel"].tap()
      try assertElementDisappears(editor)
    }

    func testCatalystEditOpensAnEditableDraftWithoutEditToggle() throws {
      launch(arguments: [fixtureArgument])
      let parentWindow = app.windows.firstMatch
      try require(parentWindow.waitForExistence(timeout: elementWaitTimeout), app.debugDescription)
      try shrinkToMinimum()
      let actions = configActions().firstMatch
      try require(actions.waitForExistence(timeout: elementWaitTimeout), app.debugDescription)
      let actionsIdentifier = actions.identifier
      let fields = try openEditor(actionsIdentifier: actionsIdentifier)
      let editor = fields.editor
      let draft = fields.draft
      let initialParentFrame = parentWindow.frame
      let initialEditorFrame = editor.frame
      let initialDraftFrame = draft.frame
      draft.tap()
      draft.typeText("\n\(savedDraftMarker)")
      try require(draftContains(draft, marker: savedDraftMarker), app.debugDescription)
      try grow()
      _ = try waitForFrame(of: parentWindow) { frame in
        frame.width > initialParentFrame.width + windowResizeTolerance
          && frame.height > initialParentFrame.height + windowResizeTolerance
      }
      _ = try waitForFrame(of: editor) { frame in
        frame.width > initialEditorFrame.width + windowResizeTolerance
          && frame.height > initialEditorFrame.height + windowResizeTolerance
      }
      _ = try waitForFrame(of: draft) { frame in
        frame.width > initialDraftFrame.width + windowResizeTolerance
          && frame.height > initialDraftFrame.height + windowResizeTolerance
      }
      try require(!editor.buttons["Edit"].exists, app.debugDescription)
      try require(!editor.buttons["Done"].exists, app.debugDescription)
      editor.buttons["Save"].tap()
      try assertElementDisappears(editor)

      let reopenedFields = try openEditor(actionsIdentifier: actionsIdentifier)
      try require(draftContains(reopenedFields.draft, marker: savedDraftMarker))
      reopenedFields.draft.tap()
      reopenedFields.draft.typeText("\n\(canceledDraftMarker)")
      reopenedFields.editor.buttons["Cancel"].tap()
      try assertElementDisappears(reopenedFields.editor)
      let finalFields = try openEditor(actionsIdentifier: actionsIdentifier)
      try require(draftContains(finalFields.draft, marker: savedDraftMarker))
      try require(!draftContains(finalFields.draft, marker: canceledDraftMarker))
      finalFields.editor.buttons["Cancel"].tap()
      try assertElementDisappears(finalFields.editor)
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
}

// MARK: - CellTunnelPhoneUITests helpers

extension CellTunnelPhoneUITests {
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

    private func dismissUserNotificationDialogIfPresented() throws {
      let notificationCenter = XCUIApplication(bundleIdentifier: notificationCenterBundleIdentifier)
      let dialog = notificationCenter.dialogs.firstMatch
      guard dialog.exists else {
        return
      }

      let denyButton = dialog.buttons["Don’t Allow"]
      try require(denyButton.waitForExistence(timeout: elementWaitTimeout))
      denyButton.tap()
      try assertElementDisappears(dialog)
    }

    private func grow() throws {
      try openWindowMenu()
      let fill = app.menuItems[fillWindowTitle]
      try require(fill.waitForExistence(timeout: elementWaitTimeout), app.debugDescription)
      fill.tap()
    }

    private func shrinkToMinimum() throws {
      try openWindowMenu()
      let moveAndResize = app.menuItems[moveAndResizeTitle]
      try require(moveAndResize.waitForExistence(timeout: elementWaitTimeout), app.debugDescription)
      moveAndResize.hover()

      let quartersSubmenu = app.menuItems.matching(
        NSPredicate(format: "identifier == %@", quartersActionIdentifier)
      ).firstMatch
      try require(
        quartersSubmenu.waitForExistence(timeout: elementWaitTimeout),
        app.debugDescription
      )
      quartersSubmenu.hover()

      let bottomRight = app.menuItems[bottomRightTitle]
      try require(bottomRight.waitForExistence(timeout: elementWaitTimeout), app.debugDescription)
      bottomRight.tap()
    }

    private func openWindowMenu() throws {
      let windowMenu = app.menuBars.menuBarItems[windowMenuTitle]
      try require(windowMenu.waitForExistence(timeout: elementWaitTimeout), app.debugDescription)
      windowMenu.tap()
    }

    private func configActions() -> XCUIElementQuery {
      app.popUpButtons.matching(
        NSPredicate(format: "identifier BEGINSWITH %@", configActionsIdentifier)
      )
    }

    private func openEditor(
      actionsIdentifier: String
    ) throws -> (editor: XCUIElement, draft: XCUIElement) {
      let actions = app.popUpButtons[actionsIdentifier]
      try require(actions.waitForExistence(timeout: elementWaitTimeout), app.debugDescription)
      actions.tap()
      let edit = app.menuItems["Edit"]
      try require(edit.waitForExistence(timeout: elementWaitTimeout), app.debugDescription)
      edit.tap()
      return try editorFields()
    }

    private func editorFields() throws -> (editor: XCUIElement, draft: XCUIElement) {
      let editor = app.otherElements[configEditorIdentifier]
      try require(editor.waitForExistence(timeout: elementWaitTimeout), app.debugDescription)
      let draft = editor.textViews.firstMatch
      try require(draft.waitForExistence(timeout: elementWaitTimeout), app.debugDescription)
      return (editor: editor, draft: draft)
    }

    private func draftContains(_ draft: XCUIElement, marker: String) -> Bool {
      String(describing: draft.value).contains(marker)
    }

    private func addScreenshot(_ screenshot: XCUIScreenshot, named name: String) {
      let attachment = XCTAttachment(screenshot: screenshot)
      attachment.name = name
      attachment.lifetime = .keepAlways
      add(attachment)
    }

    private func waitForFrame(
      of element: XCUIElement,
      matching predicate: (CGRect) -> Bool,
      failureDescription: String = "frame did not change"
    ) throws -> CGRect {
      let deadline = Date().addingTimeInterval(elementWaitTimeout)
      var lastFrame = element.frame
      while Date() < deadline {
        let frame = element.frame
        lastFrame = frame
        if predicate(frame) {
          return frame
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      }
      throw UITestFailure(message: "\(failureDescription): \(lastFrame)")
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

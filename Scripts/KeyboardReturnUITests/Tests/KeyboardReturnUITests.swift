import XCTest

/// Sends keyboard events to the production policy in an isolated native host.
/// Automatic screen capture is disabled in the scheme; no screenshots are used.
@MainActor
final class KeyboardReturnUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testMultilineReturnDismissesWithoutNewlineOrSubmit() {
        verifyReturn(control: "multiline", text: "Return test")
    }

    func testSingleLineReturnDoesNotSubmit() {
        verifyReturn(control: "single", text: "Return test")
    }

    func testSecureReturnDoesNotAdvanceOrSave() {
        verifyReturn(control: "secure", text: "test-only-passphrase")
    }

    func testNumericHardwareReturnDismissesWithoutNewline() {
        verifyReturn(control: "number", text: "123")
    }

    func testSearchReturnDismissesAndKeepsTheQuery() {
        let app = launch(control: "search", text: "bitcoin")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        app.typeText("\n")
        assertDismissed(app, text: "bitcoin")
    }

    func testRenameAlertReturnDoesNotSaveOrDismissTheAlert() {
        let app = launch(control: "alert", text: "Test wallet")
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        app.typeText("\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.alerts.firstMatch.exists)
        XCTAssertEqual(field.value as? String, "Test wallet")
        XCTAssertEqual(app.staticTexts["return.saves"].label, "0")
    }

    func testNativeDoneKeyAndRefocusingMultilineInput() {
        let app = launch(control: "multiline", text: "Return test")
        let field = input(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let done = app.keyboards.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        // A connected hardware keyboard can keep the software key offscreen.
        // Exercise an actual keyboard event in either simulator configuration.
        if done.isHittable { done.tap() }
        else { app.typeText("\n") }
        assertDismissed(app, text: "Return test")
        field.tap()
        app.typeText(" again")
        app.typeText("\n")
        assertDismissed(app, text: "Return test again")
    }

    func testReturnPreservesMultilinePastedContent() {
        let app = launch(control: "multiline", text: "", paste: "first\nsecond\nthird")
        let field = input(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.press(forDuration: 1)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        app.typeText("\n")
        assertDismissed(app, text: "first\nsecond\nthird")
    }

    func testMultilineReturnDismissesInArabicLocale() {
        let app = launch(control: "multiline", text: "ملاحظة", language: "ar", locale: "ar_AE")
        let field = input(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        app.typeText("\n")
        assertDismissed(app, text: "ملاحظة")
    }

    private func verifyReturn(control: String, text: String) {
        let app = launch(control: control, text: text)
        let field = input(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        app.typeText("\n")
        assertDismissed(app, text: text)
        app.buttons["return.save"].tap()
        XCTAssertEqual(app.staticTexts["return.saves"].label, "1")
    }

    private func launch(
        control: String, text: String, paste: String? = nil,
        language: String = "en", locale: String = "en_US"
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RETURN_CONTROL"] = control
        app.launchEnvironment["RETURN_TEXT"] = text
        app.launchEnvironment["RETURN_PASTE"] = paste
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launch()
        return app
    }

    private func input(in app: XCUIApplication) -> XCUIElement {
        // SwiftUI exposes its vertical UITextView as an accessibility text
        // field on some OS versions, so query the stable app identifier.
        if app.textFields["return.input"].exists { return app.textFields["return.input"] }
        if app.secureTextFields["return.input"].exists { return app.secureTextFields["return.input"] }
        return app.textViews["return.input"]
    }

    private func assertDismissed(_ app: XCUIApplication, text: String) {
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["return.text"].label, text)
        XCTAssertEqual(app.staticTexts["return.submissions"].label, "0")
        XCTAssertEqual(app.staticTexts["return.saves"].label, "0")
        XCTAssertEqual(app.staticTexts["return.focused"].label, "0")
    }
}

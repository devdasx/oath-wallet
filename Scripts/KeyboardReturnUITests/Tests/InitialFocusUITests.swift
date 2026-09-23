import XCTest

@MainActor
final class InitialFocusUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testMultilineAndSecureFieldsWaitForATap() {
        for control in ["multiline", "secure"] {
            let app = XCUIApplication()
            app.launchEnvironment["RETURN_CONTROL"] = control
            app.launch()
            let input = control == "secure" ? app.secureTextFields["return.input"] : app.textFields["return.input"]
            XCTAssertTrue(input.waitForExistence(timeout: 8))
            XCTAssertFalse(app.keyboards.firstMatch.exists)
            input.tap()
            app.typeText("focus test")
            XCTAssertEqual(app.staticTexts["return.text"].label, "focus test")
            app.terminate()
        }
    }

    func testSearchWaitsForATapInArabic() {
        let app = XCUIApplication()
        app.launchEnvironment["RETURN_CONTROL"] = "search"
        app.launchArguments += ["-AppleLanguages", "(ar)", "-AppleLocale", "ar"]
        app.launch()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.searchFields.firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("USD")
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "USD")
    }

    func testPushAndSheetWaitForFocusAndReopenCorrectly() {
        let app = XCUIApplication()
        app.launchEnvironment["FOCUS_NAVIGATION"] = "1"
        app.launch()
        for trigger in ["focus.push", "focus.sheet", "focus.sheet"] {
            app.buttons[trigger].tap()
            let first = app.textFields["focus.first"]
            XCTAssertTrue(first.waitForExistence(timeout: 5))
            XCTAssertFalse(app.keyboards.firstMatch.exists)
            first.tap()
            app.typeText("first")
            XCTAssertEqual(first.value as? String, "first")
            app.secureTextFields["focus.second"].tap()
            app.typeText("second\n")
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            app.buttons["focus.update"].tap()
            XCTAssertTrue(app.staticTexts["focus.updates"].waitForExistence(timeout: 3))
            XCTAssertFalse(app.keyboards.firstMatch.exists)
            app.navigationBars.buttons.firstMatch.tap()
        }
    }
}

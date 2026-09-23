import XCTest

@MainActor
final class RecoveryPhraseDeleteUITests: XCTestCase {
    func testNativeKeyboardHoldBaseline() {
        let app = launch(["--baseline"])
        app.textFields["baseline"].tap()
        app.typeText("head good wolf hand goat gadget yard ice oak jacket table vacant")
        app.keyboards.keys["delete"].press(forDuration: 12)
        XCTAssertEqual(app.staticTexts["baselineValue"].label, "")
    }

    func testHoldingSoftwareBackspaceClearsTheEntirePhrase() {
        verifyHold()
    }

    func testHoldingFromAFragmentClears24Words() {
        verifyHold(["--24", "--fragment"])
    }

    func testHoldingInArabicClears24Words() {
        verifyHold(["--24"], language: "ar")
    }

    func testReleaseStopsDeletingAndTypingReplacesTheSelectedWord() {
        let app = launch()
        let input = app.textFields["recoveryPhraseInlineInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        let delete = app.keyboards.keys["delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.press(forDuration: 0.8)
        app.typeText("new ")
        let remaining = app.staticTexts["remaining"].label
        XCTAssertNotEqual(remaining, "0:")
        // UIKit idleness and a later edit must not restart any deletion.
        app.typeText("word ")
        let beforeCount = Int(remaining.split(separator: ":")[0])!
        XCTAssertEqual(app.staticTexts["remaining"].label, "\(beforeCount + 1):")
    }

    func testCompletedPhraseResumesBeforeShowingWordMenu() {
        verifyResume(afterReturn: false)
    }

    func testReturnHidesEmptyInputAndWordTapResumes() {
        verifyResume(afterReturn: true)
    }

    private func verifyResume(afterReturn: Bool) {
        let app = launch(["--complete"] + (afterReturn ? [] : ["--dismissed"]))
        if afterReturn {
            let input = app.textFields["recoveryPhraseInlineInput"]
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.tap()
            app.typeText("\n")
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.textFields["recoveryPhraseInlineInput"].waitForNonExistence(timeout: 5))
        let word = app.buttons["recoveryPhraseWord_3"]
        XCTAssertTrue(word.waitForExistence(timeout: 5))
        word.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["recoveryPhraseInlineInput"].exists)
        XCTAssertEqual(app.staticTexts["remaining"].label, "12:")
        XCTAssertFalse(app.buttons["Edit Word"].exists)
        // Typing goes to the trailing input, not the tapped third word.
        app.typeText("new ")
        XCTAssertEqual(app.staticTexts["remaining"].label, "13:")
        word.tap()
        let edit = app.buttons["Edit Word"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Clear"].exists)
        edit.tap()
        XCTAssertEqual(app.staticTexts["remaining"].label, "13:abandon")
    }

    private func verifyHold(_ arguments: [String] = [], language: String = "en") {
        let app = launch(arguments, language: language)
        let input = app.textFields["recoveryPhraseInlineInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        // A tap in a prefilled fragment can move the caret. Typing then deleting
        // this suffix puts the insertion point at the word end deterministically.
        if arguments.contains("--fragment") { app.typeText("end") }
        let delete = app.keyboards.keys["delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.press(forDuration: 12)
        XCTAssertEqual(app.staticTexts["remaining"].label, "0:")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.typeText("new ")
        XCTAssertEqual(app.staticTexts["remaining"].label, "1:")
    }

    private func launch(_ arguments: [String] = [], language: String = "en") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = arguments + ["-AppleLanguages", "(\(language))", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }
}

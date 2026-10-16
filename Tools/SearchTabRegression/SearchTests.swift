import XCTest

@MainActor final class SearchTests: XCTestCase {
    func testSelectingAssetClosesSearchAndReturnsHome() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }

        // Repeat with keyboard visible and dismissed, and exercise both native
        // Back and interactive pop. Opening search again must start fresh.
        for (index, submit) in [(9, false), (8, true)] {
            app.tabBars.buttons["Search"].tap()
            let field = app.searchFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText("Token \(index)")
            if submit { field.typeText("\n") }
            let result = app.buttons["Token \(index)"]
            XCTAssertTrue(result.waitForExistence(timeout: 5))
            result.tap()
            XCTAssertTrue(app.staticTexts["Details \(index)"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.searchFields.firstMatch.isHittable)
            XCTAssertFalse(app.keyboards.firstMatch.exists)
            XCTAssertFalse(app.tabBars.firstMatch.isHittable)
            if submit {
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                start.press(forDuration: 0.05, thenDragTo:
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
            } else {
                app.navigationBars.buttons.firstMatch.tap()
            }
            XCTAssertTrue(app.navigationBars["Wallet"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.tabBars.buttons["Wallet"].isSelected)
            XCTAssertFalse(app.searchFields.firstMatch.isHittable)
            XCTAssertFalse(app.keyboards.firstMatch.exists)
            XCTAssertTrue(app.buttons["Token 0"].isHittable, "Home is not filtered by the old query")
        }
        app.tabBars.buttons["Search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, field.placeholderValue, "The previous query is cleared")
        XCTAssertGreaterThan(field.frame.midY, app.frame.height * 0.4, "Reopened search stays native at the bottom")
    }

    func testNativeBottomSearchAndRepeatedContextChanges() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        for context in ["Wallet", "History", "Wallet"] {
            let tabs = app.tabBars
            tabs.buttons[context].tap()
            XCTAssertFalse(app.searchFields.firstMatch.isHittable, "No top search on the browsing tabs")
            tabs.buttons["Search"].tap()
            let field = app.searchFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            let lowerBound = app.keyboards.firstMatch.exists
                ? app.keyboards.firstMatch.frame.minY : app.frame.maxY
            XCTAssertGreaterThan(field.frame.midY, app.frame.height * 0.4)
            XCTAssertLessThan(lowerBound - field.frame.maxY, 160, "Search stays immediately above keyboard/tab area")
            XCTAssertEqual(field.placeholderValue, context == "History" ? "Search transactions" : "Search assets or contract address")
            field.tap()
            field.typeText("Token 9")
            XCTAssertTrue(app.buttons["Token 99"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Token 0"].exists)
            field.typeText("\n")
            XCTAssertFalse(app.keyboards.firstMatch.exists)
            XCTAssertGreaterThan(field.frame.midY, app.frame.height * 0.7,
                                 "After submitting, native search must not move into the top drawer")
            let cancel = app.buttons["Close"]
            XCTAssertTrue(cancel.waitForExistence(timeout: 5))
            cancel.tap()
            XCTAssertFalse(app.keyboards.firstMatch.exists)
            if field.isHittable {
                XCTAssertGreaterThan(field.frame.midY, app.frame.height * 0.7, "Dismissed search must stay at the bottom")
            }
        }
    }
}

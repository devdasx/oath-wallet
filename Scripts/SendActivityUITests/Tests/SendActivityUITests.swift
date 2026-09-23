import XCTest

@MainActor final class SendActivityUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }

    func testToolbarOpensNativeListAndExactReceiptInBothLanguages() {
        for language in ["en", "ar"] {
            let app = launch(language: language)
            let toolbar = app.buttons["wallet-home-pending-activity"]
            assertPendingCount(2, on: toolbar)
            toolbar.tap()
            XCTAssertTrue(row(1, app).waitForExistence(timeout: 3))
            let bar = app.navigationBars.containing(.button, identifier: "pending-activity-close").firstMatch
            XCTAssertTrue(bar.exists, "Activity must use a native navigation bar for its close action")
            XCTAssertTrue(bar.staticTexts[language == "ar" ? "النشاط" : "Activity"].exists)
            row(1, app).tap()
            XCTAssertTrue(app.staticTexts["fixture-selected-recipient"].waitForExistence(timeout: 3))
            XCTAssertEqual(app.staticTexts["fixture-selected-recipient"].label, "Recipient-1")
            app.buttons["fixture-close"].tap()
            XCTAssertTrue(toolbar.waitForExistence(timeout: 3))
            // Closing pending details never removes a still-pending transaction from the toolbar.
            assertPendingCount(2, on: toolbar)
            app.terminate()
        }
    }

    func testBannerHasNoCountAndOpensOnlyItsOwnTransaction() {
        let app = launch()
        XCTAssertFalse(app.buttons["sendActivityCountBadge"].exists)
        app.buttons["sendStatusCapsule"].tap()
        XCTAssertTrue(app.staticTexts["fixture-selected-recipient"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["fixture-selected-recipient"].label, "Recipient-1")
    }

    func testNativeCloseKeepsPendingCountAndCanReopen() {
        for language in ["en", "ar"] {
            let app = launch(language: language)
            let toolbar = app.buttons["wallet-home-pending-activity"]
            toolbar.tap()
            app.buttons["pending-activity-close"].tap()
            XCTAssertTrue(app.buttons["pending-activity-close"].waitForNonExistence(timeout: 3))
            assertPendingCount(2, on: toolbar)
            toolbar.tap()
            XCTAssertTrue(row(0, app).waitForExistence(timeout: 3))
            app.terminate()
        }
    }

    func testShortListSwipeDismissesWithoutLosingPendingTransactions() {
        let app = launch()
        let toolbar = app.buttons["wallet-home-pending-activity"]
        toolbar.tap()
        let start = row(0, app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -80)))
        XCTAssertTrue(app.buttons["pending-activity-close"].waitForNonExistence(timeout: 3))
        assertPendingCount(2, on: toolbar)
        XCTAssertFalse(app.staticTexts["fixture-selected-recipient"].exists)
    }

    func testLargeTextListScrollsAndSelectsOldestInBothLanguages() {
        for language in ["en", "ar"] {
            let app = launch(language: language, extra: ["fixture-many", "fixture-large-text"])
            app.buttons["wallet-home-pending-activity"].tap()
            let bar = app.navigationBars.containing(.button, identifier: "pending-activity-close").firstMatch
            XCTAssertTrue(bar.waitForExistence(timeout: 3))
            let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -90)))
            XCTAssertTrue(app.buttons["pending-activity-close"].waitForNonExistence(timeout: 3))
            app.buttons["wallet-home-pending-activity"].tap()
            let list = app.collectionViews["pending-activity-list"]
            XCTAssertTrue(list.waitForExistence(timeout: 3))
            for _ in 0..<20 {
                if row(0, app).exists && row(0, app).isHittable { break }
                list.swipeUp()
            }
            XCTAssertTrue(row(0, app).isHittable)
            row(0, app).tap()
            XCTAssertTrue(app.staticTexts["fixture-selected-recipient"].waitForExistence(timeout: 3))
            XCTAssertEqual(app.staticTexts["fixture-selected-recipient"].label, "Recipient-0")
            app.terminate()
        }
    }

    func testFailureIsCountedUntilReviewedAndConfirmationReducesCount() {
        let app = launch()
        let toolbar = app.buttons["wallet-home-pending-activity"]
        app.buttons["fixture-fail"].tap()
        assertPendingCount(2, on: toolbar)
        toolbar.tap()
        row(1, app).tap()
        XCTAssertTrue(app.buttons["fixture-close"].waitForExistence(timeout: 3))
        app.buttons["fixture-close"].tap()
        assertPendingCount(1, on: toolbar)
        app.buttons["fixture-confirm"].tap()
        assertPendingCount(1, on: toolbar)
    }

    func testNativePopoverSurvivesRotationAndContainsNoRecipients() {
        let app = launch()
        app.buttons["wallet-home-pending-activity"].tap()
        XCTAssertFalse(row(1, app).label.contains("Recipient"))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["pending-activity-close"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["pending-activity-close"].isHittable)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["pending-activity-close"].isHittable)
        app.buttons["pending-activity-close"].tap()
        XCTAssertTrue(app.buttons["pending-activity-close"].waitForNonExistence(timeout: 3))
    }

    private func assertPendingCount(
        _ expected: Int, on toolbar: XCUIElement,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        // Native icon-only toolbar badges add localized wording (for example,
        // "2 items"). Verify the exact ASCII count without depending on that wording.
        let value = toolbar.value as? String
        let digits = value.map { $0.filter { $0 >= "0" && $0 <= "9" } }
        XCTAssertEqual(digits, String(expected), "Badge value: \(value ?? "missing")", file: file, line: line)
    }

    private func row(_ index: Int, _ app: XCUIApplication) -> XCUIElement {
        app.buttons[String(format: "pending-activity-row-send:00000000-0000-0000-0000-%012d", index)]
    }
    private func launch(language: String = "en", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language] + extra
        app.launch()
        XCTAssertTrue(app.buttons["wallet-home-pending-activity"].waitForExistence(timeout: 5))
        return app
    }
}

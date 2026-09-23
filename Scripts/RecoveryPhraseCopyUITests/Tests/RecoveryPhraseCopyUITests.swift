import XCTest

/// Actual taps on the production native List rows. Screen capture is disabled.
@MainActor
final class RecoveryPhraseCopyUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testQuickCreationCopyUpdatesLabel() {
        verifyCopy(screen: "quick")
    }

    func testPhysicalEntropyCopyUpdatesLabel() {
        verifyCopy(screen: "entropy")
    }

    func testRecoveryDisplayCopyUpdatesLabel() {
        verifyCopy(screen: "display")
    }

    func testArabicCopyUpdatesLabel() {
        verifyCopy(screen: "quick", arabic: true)
    }

    func testLargeTextDarkModeCopyUpdatesLabel() {
        verifyCopy(screen: "quick", largeText: true, dark: true)
    }

    func testLandscapeCopyUpdatesLabel() {
        verifyCopy(screen: "entropy", landscape: true)
    }

    private func verifyCopy(
        screen: String, arabic: Bool = false, largeText: Bool = false,
        dark: Bool = false, landscape: Bool = false
    ) {
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        app.launchEnvironment = [
            "COPY_SCREEN": screen, "COPY_LARGE_TEXT": largeText ? "1" : "0",
            "COPY_DARK": dark ? "1" : "0"
        ]
        app.launchArguments = [
            "-AppleLanguages", arabic ? "(ar)" : "(en)",
            "-AppleLocale", arabic ? "ar_AE" : "en_US"
        ]
        app.launch()
        let ready = arabic ? "نسخ إلى الحافظة" : "Copy to Clipboard"
        let copied = arabic ? "تم النسخ إلى الحافظة" : "Copied to Clipboard"
        let copyButton = app.buttons[ready]
        scrollTo(copyButton, in: app)
        copyButton.tap()
        XCTAssertTrue(app.buttons[copied].waitForExistence(timeout: 3),
                      "Copy must update its visible and accessible label immediately")
        XCTAssertEqual(app.staticTexts["copy.fixture.matches"].label, "1",
                       "Copy must write the exact synthetic words in order")

        // A copied button stays usable; repeated taps must not toggle back.
        let previousChanges = Int(app.staticTexts["copy.fixture.changes"].label) ?? 0
        app.buttons[copied].tap()
        XCTAssertTrue(app.buttons[copied].exists)
        XCTAssertGreaterThan(Int(app.staticTexts["copy.fixture.changes"].label) ?? 0,
                             previousChanges)

        XCTAssertTrue(app.buttons[ready].waitForExistence(timeout: 3),
                      "Copied feedback must return to ready after two seconds")
        XCTAssertFalse(app.buttons[copied].exists)

        // A newly displayed phrase must not inherit the previous confirmation.
        app.buttons[ready].tap()
        XCTAssertTrue(app.buttons[copied].waitForExistence(timeout: 3))
        app.buttons["copy.fixture.changeWords"].tap()
        scrollTo(app.buttons[ready], in: app)
        XCTAssertFalse(app.buttons[copied].exists)
        app.buttons[ready].tap()
        XCTAssertTrue(app.buttons[copied].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["copy.fixture.matches"].label, "1")
    }

    private func scrollTo(_ button: XCUIElement, in app: XCUIApplication) {
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 3))
        for _ in 0..<16 {
            // A List cell can report hittable while its center is behind the
            // screen's bottom Continue bar. Scroll inside the visible list,
            // not over the toolbar, and require the whole copy row to fit.
            let top = max(list.frame.minY, app.navigationBars.firstMatch.frame.maxY)
            let continueButton = app.buttons["Continue"]
            let bottom = continueButton.exists
                ? min(list.frame.maxY, continueButton.frame.minY)
                : list.frame.maxY
            if button.exists && button.isHittable
                && button.frame.minY >= top
                && button.frame.maxY <= bottom {
                return
            }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let visibleHeight = bottom - top
            let start = origin.withOffset(CGVector(dx: list.frame.midX,
                                                   dy: top + visibleHeight * 0.75))
            let end = origin.withOffset(CGVector(dx: list.frame.midX,
                                                 dy: top + visibleHeight * 0.25))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Recovery copy row must remain reachable: \(app.debugDescription)")
    }
}

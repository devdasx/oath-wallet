import XCTest

/// Focused coverage for embedded native search, keyboard insets, and returning
/// to the same measured sheet after changing reading direction.
final class OathLanguageSheetUITests: XCTestCase {
    @MainActor func testNativeTopSearchAndLanguageState() {
        runFlow(largeText: false)
    }
    @MainActor func testLargeTextSearchRemainsReachable() {
        runFlow(largeText: true)
    }

    @MainActor private func runFlow(largeText: Bool) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-oath.languagePreference", "en"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        let more = app.buttons["onboarding.moreOptions"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        reveal(more, scroll: app.scrollViews["onboarding.actionsPane"])
        more.tap()
        openLanguages(in: app)
        let search = app.searchFields["settings.languageSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(search.isHittable)
        XCTAssertLessThan(search.frame.midY, app.frame.height * 0.4, "Search stays in the top navigation bar")
        XCTAssertEqual(app.buttons.matching(identifier: "Sheet Grabber").count, 1, "Language replaces content inside one sheet")
        search.tap()
        search.typeText("Arabic")
        let arabic = app.cells["language.choice.ar"]
        XCTAssertTrue(arabic.waitForExistence(timeout: 5))
        XCTAssertTrue(arabic.isHittable)
        let labels = ([arabic.label] + arabic.staticTexts.allElementsBoundByIndex.map(\.label)).joined(separator: " ")
        XCTAssertTrue(labels.contains("العربية"))
        XCTAssertTrue(labels.contains("Arabic"))
        if app.keyboards.firstMatch.exists {
            XCTAssertLessThanOrEqual(arabic.frame.maxY, app.keyboards.firstMatch.frame.minY + 1, "Results stay above the keyboard")
        }
        capture(largeText ? "Large text native top search" : "Native top search with bilingual Arabic", app)
        arabic.tap()
        let title = app.navigationBars.staticTexts["المزيد من الخيارات"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "المزيد من الخيارات")
        XCTAssertEqual(app.buttons.matching(identifier: "Sheet Grabber").count, 1)
        XCTAssertLessThan(app.buttons["options.close"].frame.midX, app.frame.midX)
        capture(largeText ? "Large text Arabic options" : "Arabic options after language change", app)

        openLanguages(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Hebrew")
        let hebrew = app.cells["language.choice.he"]
        XCTAssertTrue(hebrew.waitForExistence(timeout: 5))
        XCTAssertTrue(hebrew.isHittable)
        capture(largeText ? "Large text Arabic language picker" : "Arabic picker with Hebrew result", app)
        hebrew.tap()
        let englishTitle = app.navigationBars.staticTexts["More Options"]
        XCTAssertTrue(englishTitle.waitForExistence(timeout: 5), "New-language app copy remains English as requested")
        XCTAssertLessThan(app.buttons["options.close"].frame.midX, app.frame.midX, "Hebrew uses native RTL despite English placeholder copy")

        openLanguages(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("English")
        let english = app.cells["language.choice.en"]
        XCTAssertTrue(english.waitForExistence(timeout: 5))
        english.tap()
        XCTAssertTrue(englishTitle.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.buttons["options.close"].frame.midX, app.frame.midX)
        app.buttons["options.close"].tap()
        XCTAssertFalse(app.buttons["options.close"].exists, "Close dismisses the only sheet")
        app.terminate()
    }

    @MainActor private func openLanguages(in app: XCUIApplication) {
        let language = app.buttons["settings.language"]
        XCTAssertTrue(language.waitForExistence(timeout: 5))
        reveal(language, scroll: app.scrollViews["options.scrollContent"])
        language.tap()
    }
    @MainActor private func reveal(_ element: XCUIElement, scroll: XCUIElement) {
        for _ in 0..<6 where !element.isHittable { scroll.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    @MainActor override func tearDown() async throws {
        guard let run = testRun, run.totalFailureCount > 0 else { return }
        let app = XCUIApplication()
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Language sheet failure hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        capture("Language sheet failure", app)
    }
}

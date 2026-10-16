import XCTest

/// Covers the runtime contract that compilation cannot establish: the native
/// presentation resizes while one sheet changes content, including RTL text.
final class OathOptionsSheetUITests: XCTestCase {
    @MainActor override func tearDown() async throws {
        if let run = testRun, run.totalFailureCount > 0 {
            let app = XCUIApplication()
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "Sheet failure hierarchy"
            tree.lifetime = .keepAlways
            add(tree)
            capture("Sheet failure", app)
        }
    }

    @MainActor func testRestoreResizesTheExistingSheet() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-oath.languagePreference", "en"]
        app.launch()
        let more = app.buttons["onboarding.moreOptions"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        capture("Gray More Options", app)
        more.tap()
        let restore = app.buttons["onboarding.restoreICloud"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        let close = app.buttons["options.close"]
        XCTAssertTrue(close.isHittable)
        let closeSize = nativeCloseSize(in: app)
        let grabber = app.buttons["Sheet Grabber"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        let optionsY = grabber.frame.midY
        XCTAssertGreaterThan(optionsY, app.frame.height * 0.4,
                             "Short content must open as a short sheet, not a large presentation")
        capture("Content-fitted options", app)

        restore.tap()
        XCTAssertTrue(app.staticTexts["No backups yet"].waitForExistence(timeout: 5))
        XCTAssertTrue(close.isHittable)
        XCTAssertEqual(nativeCloseSize(in: app).width, closeSize.width, accuracy: 0.5)
        XCTAssertEqual(nativeCloseSize(in: app).height, closeSize.height, accuracy: 0.5)
        XCTAssertFalse(restore.exists)
        capture("Restore in the same sheet", app)
        XCTAssertGreaterThan(abs(grabber.frame.midY - optionsY), 1,
                             "The native sheet must resize when its content changes")
        let back = app.buttons["icloud.backToOptions"]
        XCTAssertEqual(back.frame.width, close.frame.width, accuracy: 1, "Sheet Back is an icon-only native item")
        back.tap()
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        XCTAssertEqual(grabber.frame.midY, optionsY, accuracy: 1,
                       "Returning to options restores its content-fitted size")

        let language = app.descendants(matching: .any).matching(identifier: "settings.language").firstMatch
        language.tap()
        let search = app.searchFields["settings.languageSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertEqual(nativeCloseSize(in: app).width, closeSize.width, accuracy: 0.5, "Every sheet uses the language Close control")
        XCTAssertEqual(nativeCloseSize(in: app).height, closeSize.height, accuracy: 0.5)
        XCTAssertEqual(app.buttons["language.back"].frame.width, close.frame.width, accuracy: 1)
        capture("Shared native sheet controls", app)
        search.tap()
        search.typeText("Arabic")
        let arabic = app.cells["language.choice.ar"]
        XCTAssertTrue(arabic.waitForExistence(timeout: 5))
        arabic.tap()
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        capture("Arabic content-fitted options", app)
        let arabicOptionsY = grabber.frame.midY
        restore.tap()
        XCTAssertTrue(app.staticTexts["لا توجد نسخ احتياطية بعد"].waitForExistence(timeout: 5))
        capture("Arabic restore in the same sheet", app)
        XCTAssertGreaterThan(abs(grabber.frame.midY - arabicOptionsY), 1)
        close.tap()
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        XCTAssertFalse(close.exists, "Close dismisses the whole presentation, with no older sheet underneath")

    }

    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    @MainActor func testLargestTextRemainsReachableInPortrait() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-oath.languagePreference", "en",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let more = app.buttons["onboarding.moreOptions"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        reveal(more, scrolling: app.scrollViews["onboarding.actionsPane"])
        more.tap()
        let close = app.buttons["options.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(close.isHittable)
        XCTAssertGreaterThan(app.buttons["onboarding.restoreICloud"].frame.height, 100,
                             "The test must actually run with accessibility-sized text")
        capture("Largest text options portrait", app)

        let content = app.scrollViews["options.scrollContent"]
        let language = app.buttons["settings.language"]
        reveal(language, scrolling: content)
        language.tap()
        let search = app.searchFields["settings.languageSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Arabic")
        let arabic = app.cells["language.choice.ar"]
        XCTAssertTrue(arabic.waitForExistence(timeout: 5))
        arabic.tap()
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(content.frame.maxY, app.frame.maxY + 1)
        XCTAssertGreaterThanOrEqual(content.frame.minY, app.frame.minY - 1)
        reveal(language, scrolling: content)
        capture("Largest Arabic text portrait scroll end", app)
        for _ in 0..<5 where !close.isHittable { content.swipeDown() }
        XCTAssertTrue(close.isHittable)
        capture("Largest Arabic text portrait header", app)

        let restore = app.buttons["onboarding.restoreICloud"]
        // The native header stays pinned. isHittable can be true for a sliver
        // of a tall row under the bar; reveal its leading edge before tapping.
        let bar = app.navigationBars.containing(.button, identifier: "options.close").firstMatch
        for _ in 0..<8 where restore.frame.minY < bar.frame.maxY { content.swipeDown() }
        reveal(restore, scrolling: content)
        restore.tap()
        let back = app.buttons["icloud.backToOptions"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        reveal(back, scrolling: content)
        capture("Largest Arabic text portrait restore", app)
        back.tap()
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        XCTAssertTrue(close.isHittable, "Returning to options resets scrolling to the header")
        close.tap()
        XCTAssertFalse(close.exists)
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor private func reveal(_ element: XCUIElement, scrolling scroll: XCUIElement,
                                   file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<6 where !element.isHittable { scroll.swipeUp() }
        XCTAssertTrue(element.isHittable, "Content must remain reachable by scrolling", file: file, line: line)
    }

    @MainActor private func nativeCloseSize(in app: XCUIApplication) -> CGSize {
        let close = app.buttons["options.close"]
        let bar = app.navigationBars.containing(.button, identifier: "options.close").firstMatch
        // iOS scales the entire floating compact sheet to inset its sides.
        // Compare native dimensions, not that presentation-wide transform.
        let scale = app.frame.width / bar.frame.width
        let size = CGSize(width: close.frame.width * scale, height: close.frame.height * scale)
        print("OATH_NATIVE_CLOSE_SIZE \(size.width) x \(size.height); sheet bar width \(bar.frame.width)")
        return size
    }
}

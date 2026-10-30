import XCTest

/// Public BIP-39 fixtures only. These checks never save a passcode, import a
/// live wallet, access the clipboard, or use a physical camera.
final class OathRecoveryImportUITests: XCTestCase {
    @MainActor
    func test01KeyboardCompletionValidationAndNavigation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-oath.languagePreference", "en"]
        app.launch()
        app.buttons["onboarding.importWallet"].tap()
        let field = app.textViews["recovery.phrase"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(field.isHittable)
        field.typeText("aba")
        let suggestion = app.buttons["recovery.suggestion.0"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5))
        XCTAssertEqual(suggestion.label, "abandon")
        suggestion.tap()
        XCTAssertEqual(field.value as? String, "abandon ")
        field.typeText(String(repeating: "abandon ", count: 10) + "ability")
        XCTAssertEqual(field.value as? String, String(repeating: "abandon ", count: 11) + "ability")
        let submit = app.buttons["recovery.import"]
        revealImport(in: app)
        XCTAssertTrue(submit.isHittable)
        submit.tap()
        XCTAssertTrue(app.staticTexts["This phrase isn’t valid. Check every word and its order."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["This phrase isn’t valid. Check every word and its order."].isHittable)
        XCTAssertFalse(app.staticTexts["passcode.title"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["onboarding.importWallet"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(String(repeating: "abandon ", count: 11) + "about")
        XCTAssertEqual(field.value as? String, String(repeating: "abandon ", count: 11) + "about")
        XCTAssertTrue(app.staticTexts["Recovery phrase is valid."].waitForExistence(timeout: 5))
        revealImport(in: app)
        attach(app, name: "recovery-valid-keyboard")
        submit.tap()
        XCTAssertTrue(app.staticTexts["passcode.title"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["passcode.title"].label, "Set a Passcode")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, String(repeating: "abandon ", count: 11) + "about")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["onboarding.importWallet"].waitForExistence(timeout: 5))
        app.buttons["onboarding.importWallet"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "")
        app.buttons["recovery.keyboardDone"].tap()
        app.buttons["recovery.scan"].tap()
        XCTAssertTrue(app.alerts["Unable to scan"].waitForExistence(timeout: 8))
        app.alerts.buttons["Close"].tap()
        XCTAssertEqual(field.value as? String, "")
    }

    @MainActor
    func test02ArabicLargestTextKeepsInputAndActionReachable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-oath.languagePreference", "ar",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let open = app.buttons["onboarding.importWallet"]
        XCTAssertTrue(open.waitForExistence(timeout: 8))
        for _ in 0..<6 where !open.isHittable { app.scrollViews["onboarding.actionsPane"].swipeUp() }
        open.tap()
        let field = app.textViews["recovery.phrase"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(field.isHittable)
        field.typeText("aba")
        let suggestion = app.buttons["recovery.suggestion.0"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5))
        suggestion.tap()
        XCTAssertEqual(field.value as? String, "abandon ")
        let submit = app.buttons["recovery.import"]
        // Keep growing the field beyond the visible area at the largest size.
        field.typeText(String(repeating: "abandon ", count: 22) + "ability")
        XCTAssertEqual(field.value as? String, String(repeating: "abandon ", count: 23) + "ability")
        // Long synthetic text entry can leave the input accessory docked while
        // the software keyboard is minimized. Reopen it through native editing
        // so this assertion specifically checks the software-keyboard layout.
        app.buttons["recovery.keyboardDone"].tap()
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.isHittable)
        XCTAssertLessThanOrEqual(app.keyboards.firstMatch.frame.maxY, app.frame.maxY + 1)
        attach(app, name: "recovery-arabic-largest-text-keyboard")
        revealImport(in: app)
        XCTAssertTrue(submit.isHittable)
        submit.tap()
        XCTAssertTrue(app.staticTexts["هذه العبارة غير صالحة. تحقق من كل كلمة ومن ترتيب الكلمات."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["هذه العبارة غير صالحة. تحقق من كل كلمة ومن ترتيب الكلمات."].isHittable)
        XCTAssertFalse(app.staticTexts["passcode.title"].exists)
        attach(app, name: "recovery-arabic-largest-text-error")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
    }

    @MainActor
    func test03SuggestionRowScrollsWithoutSelectingAndFitsLargeText() {
        continueAfterFailure = false
        for language in ["en", "ar"] {
            let app = XCUIApplication()
            app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-oath.languagePreference", language]
            if language == "ar" {
                app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            }
            app.launch()
            let open = app.buttons["onboarding.importWallet"]
            XCTAssertTrue(open.waitForExistence(timeout: 8))
            for _ in 0..<6 where !open.isHittable { app.scrollViews["onboarding.actionsPane"].swipeUp() }
            open.tap()
            let field = app.textViews["recovery.phrase"]
            XCTAssertTrue(field.waitForExistence(timeout: 8))
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
            field.typeText("a")
            let suggestions = app.collectionViews["recovery.suggestions"]
            let first = app.buttons["recovery.suggestion.0"]
            let later = app.buttons["recovery.suggestion.4"]
            let done = app.buttons["recovery.keyboardDone"]
            XCTAssertTrue(first.waitForExistence(timeout: 5))
            XCTAssertEqual(first.label, "abandon")
            XCTAssertTrue(done.isHittable)
            XCTAssertLessThan(suggestions.frame.maxY, app.keyboards.firstMatch.frame.minY - 8)
            let firstX = first.frame.minX
            // Begin on a word, not empty space: the swipe must cancel its tap.
            suggestions.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
                .press(forDuration: 0.05,
                       thenDragTo: suggestions.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
            XCTAssertEqual(field.value as? String, "a")
            XCTAssertTrue(!first.exists || first.frame.minX < firstX)
            for _ in 0..<12 where !later.isHittable {
                // Short drags avoid flinging past the target word.
                let movingLeft = !later.exists || later.frame.midX > suggestions.frame.midX
                let start: CGFloat = movingLeft ? 0.8 : 0.2
                let end: CGFloat = movingLeft ? 0.2 : 0.8
                suggestions.coordinate(withNormalizedOffset: CGVector(dx: start, dy: 0.5))
                    .press(forDuration: 0.05,
                           thenDragTo: suggestions.coordinate(withNormalizedOffset: CGVector(dx: end, dy: 0.5)),
                           withVelocity: .slow, thenHoldForDuration: 0.2)
            }
            XCTAssertTrue(later.isHittable)
            XCTAssertEqual(later.label, "above")
            attach(app, name: "recovery-shared-glass-\(language)")
            later.tap()
            XCTAssertEqual(field.value as? String, "above ")
            // A new prefix should restart the row rather than retain its offset.
            field.typeText("a")
            XCTAssertTrue(first.isHittable)
            XCTAssertGreaterThanOrEqual(first.frame.minX, suggestions.frame.minX - 1)
            done.tap()
            XCTAssertFalse(app.keyboards.firstMatch.exists)
            app.terminate()
        }
    }

    @MainActor
    func test04GrowingFieldKeepsScanAndPasteInsideAndImportInNavigationBar() {
        continueAfterFailure = false
        for language in ["en", "ar"] {
            let app = XCUIApplication()
            app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-oath.languagePreference", language]
            if language == "ar" {
                app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            }
            app.launch()
            let open = app.buttons["onboarding.importWallet"]
            XCTAssertTrue(open.waitForExistence(timeout: 8))
            for _ in 0..<6 where !open.isHittable { app.scrollViews["onboarding.actionsPane"].swipeUp() }
            open.tap()
            let field = app.textViews["recovery.phrase"]
            let container = app.otherElements["recovery.field"]
            let paste = app.buttons["recovery.paste"]
            let scan = app.buttons["recovery.scan"]
            let clear = app.buttons["recovery.clear"]
            let submit = app.navigationBars.buttons["recovery.import"]
            XCTAssertTrue(field.waitForExistence(timeout: 8))
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
            XCTAssertTrue(submit.isHittable)
            XCTAssertFalse(submit.isEnabled)
            XCTAssertTrue(container.buttons["recovery.scan"].exists)
            XCTAssertFalse(app.navigationBars.buttons["recovery.scan"].exists)
            if !scan.isHittable || !paste.isHittable { app.buttons["recovery.keyboardDone"].tap() }
            for _ in 0..<8 where !scan.isHittable || !paste.isHittable {
                app.scrollViews["recovery.content"].swipeUp()
            }
            XCTAssertTrue(container.frame.contains(scan.frame))
            XCTAssertTrue(container.frame.contains(paste.frame))
            if language == "en" { XCTAssertLessThan(scan.frame.maxX, paste.frame.minX) }
            else { XCTAssertLessThan(paste.frame.maxX, scan.frame.minX) }
            field.tap()
            let emptyHeight = container.frame.height
            // Even the default body size has room for three lines before the
            // action area, instead of collapsing to one line when empty.
            XCTAssertGreaterThanOrEqual(field.frame.height, 90)
            XCTAssertFalse(app.staticTexts["recovery.validation"].exists)
            if language == "en" { attach(app, name: "recovery-inline-tools-empty-en") }
            field.typeText("aba")
            let suggestion = app.buttons["recovery.suggestion.0"]
            XCTAssertTrue(suggestion.waitForExistence(timeout: 5))
            suggestion.tap()
            XCTAssertEqual(field.value as? String, "abandon ")
            // UITextView's accessibility frame is clipped by the keyboard.
            // Compare the entire field, whose layout frame isn't clipped.
            XCTAssertEqual(container.frame.height, emptyHeight, accuracy: 1)
            XCTAssertFalse(app.staticTexts["recovery.validation"].exists)
            field.typeText(String(repeating: "abandon ", count: 22) + "ability")
            XCTAssertGreaterThan(container.frame.height, emptyHeight + 10)
            // Import remains in the native bar even as the input grows beyond
            // the viewport. A nonempty draft replaces Scan/Paste with Clear.
            XCTAssertTrue(submit.isHittable)
            XCTAssertTrue(submit.isEnabled)
            XCTAssertFalse(paste.exists)
            XCTAssertFalse(scan.exists)
            app.buttons["recovery.keyboardDone"].tap()
            for _ in 0..<8 where !clear.isHittable { app.scrollViews["recovery.content"].swipeUp() }
            XCTAssertTrue(clear.isHittable)
            XCTAssertTrue(container.frame.contains(clear.frame))
            XCTAssertGreaterThanOrEqual(clear.frame.height, 44)
            XCTAssertFalse(app.staticTexts["recovery.validation"].exists)
            attach(app, name: "recovery-inline-tools-grown-\(language)")
            clear.tap()
            XCTAssertTrue(paste.waitForExistence(timeout: 3))
            XCTAssertTrue(scan.exists)
            XCTAssertFalse(submit.isEnabled)
            app.terminate()
        }
    }

    @MainActor
    func test05SuggestionSurfaceFitsEmptySingleAndChangingResults() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-oath.languagePreference", "en"]
        app.launch()
        app.buttons["onboarding.importWallet"].tap()
        let field = app.textViews["recovery.phrase"]
        let surface = app.otherElements["recovery.suggestionSurface"]
        let done = app.buttons["recovery.keyboardDone"]
        let suggestions = app.collectionViews["recovery.suggestions"]
        let first = app.buttons["recovery.suggestion.0"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(surface.exists)
        let compactWidth = surface.frame.width
        XCTAssertEqual(compactWidth, done.frame.width, accuracy: 1)
        XCTAssertFalse(first.exists)
        let rightEdge = done.frame.maxX
        attach(app, name: "recovery-compact-keyboard-control")
        // Use actual key taps for motion review; synthetic typeText can
        // temporarily minimize the software keyboard in the simulator.
        app.keyboards.keys["a"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertEqual(first.label, "abandon")
        let expandedWidth = surface.frame.width
        XCTAssertGreaterThan(expandedWidth, compactWidth * 3)
        XCTAssertEqual(done.frame.maxX, rightEdge, accuracy: 1)
        XCTAssertLessThan(suggestions.frame.maxY, app.keyboards.firstMatch.frame.minY - 8)
        attach(app, name: "recovery-expanded-suggestions")
        app.keyboards.keys["b"].tap()
        XCTAssertEqual(first.label, "abandon")
        // Consecutive keystrokes exercise coalescing during native list diffs.
        field.typeText("andon")
        XCTAssertEqual(first.label, "abandon")
        XCTAssertGreaterThan(surface.frame.width, compactWidth)
        XCTAssertLessThan(surface.frame.width, expandedWidth)
        attach(app, name: "recovery-single-suggestion")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7))
        XCTAssertEqual(field.value as? String, "")
        XCTAssertEqual(surface.frame.width, compactWidth, accuracy: 1)
        // UIKit can retain recycled cells in the accessibility snapshot when
        // the collection collapses to zero width. Check the actual visible
        // control surface and hit testing, not whether a reused cell exists.
        XCTAssertFalse(first.isHittable)
        field.typeText("zzzz")
        XCTAssertFalse(first.isHittable)
        XCTAssertEqual(surface.frame.width, compactWidth, accuracy: 1)
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "aband")
        XCTAssertEqual(first.label, "abandon")
        first.tap()
        XCTAssertEqual(field.value as? String, "abandon ")
        XCTAssertEqual(surface.frame.width, compactWidth, accuracy: 1)
        XCTAssertEqual(done.frame.maxX, rightEdge, accuracy: 1)
        XCTAssertTrue(done.isHittable)
        done.tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }

    @MainActor private func revealImport(in app: XCUIApplication) {
        // Native navigation keeps confirmation reachable above the keyboard,
        // independent of the input's height or scroll position.
        XCTAssertTrue(app.navigationBars.buttons["recovery.import"].isHittable)
    }

    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor override func tearDown() async throws {
        guard let run = testRun, run.totalFailureCount > 0 else { return }
        let app = XCUIApplication()
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Recovery import failure hierarchy (public fixtures only)"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        attach(app, name: "recovery-import-failure")
    }
}

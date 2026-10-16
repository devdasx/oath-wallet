import XCTest
import UIKit

/// One disposable simulator, public test vector, no enrollment or network jobs.
/// Covers the uncertain UIKit boundary: live blur over an active sheet/search.
final class OathLockPresentationUITests: XCTestCase {
    /// Run after installing either legacy launch fixture over the same app ID.
    /// An install-over-update preserves iOS's saved scene delegate; a clean
    /// installation by itself cannot catch the Missing AppGraph regression.
    @MainActor func testRestoredSceneSurvivesColdLaunchAndForeground() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-oath.walletTestScope", UUID().uuidString, "-oath-artwork-reduce-motion"]
        defer { app.terminate() }

        for iteration in 0..<2 {
            // Attach to a manually launched install-over-update on the first
            // pass. XCTest.launch() would terminate that restored scene first.
            if iteration == 0 { app.activate() }
            else { app.launch() }
            let more = app.buttons["onboarding.moreOptions"]
            XCTAssertTrue(more.waitForExistence(timeout: 15))
            XCTAssertTrue(more.isHittable, "Restored content must be usable, not just a living process")
            more.tap()
            let close = app.buttons["options.close"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            close.tap()
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertTrue(more.waitForExistence(timeout: 5))
            XCTAssertTrue(more.isHittable)
            app.terminate()
        }
    }

    @MainActor private func createWallet() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-oath.languagePreference", "en", "-oath.walletTestScope", UUID().uuidString,
                               "-oath-artwork-reduce-motion"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.importWallet"].waitForExistence(timeout: 15))
        app.buttons["onboarding.importWallet"].tap()
        let phrase = app.textViews["recovery.phrase"]
        XCTAssertTrue(phrase.waitForExistence(timeout: 8))
        phrase.typeText(String(repeating: "abandon ", count: 11) + "about")
        app.buttons["recovery.keyboardDone"].tap()
        app.buttons["recovery.import"].tap()
        XCTAssertTrue(app.staticTexts["passcode.title"].waitForExistence(timeout: 8))
        enterPIN(app)
        let confirmation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Confirm Passcode"),
                                                     object: app.staticTexts["passcode.title"])
        XCTAssertEqual(XCTWaiter.wait(for: [confirmation], timeout: 8), .completed)
        enterPIN(app)
        app.completeWalletCustomization()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 20))
        return app
    }

    @MainActor func testWalletCustomizationKeyboardLayoutAndApply() {
        let app = createWallet()
        defer { app.terminate() }
        app.buttons["home.settings"].tap()
        let wallets = app.buttons["settings.wallets"]
        XCTAssertTrue(wallets.waitForExistence(timeout: 5))
        wallets.tap()
        let wallet = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.wallet.")).firstMatch
        XCTAssertTrue(wallet.waitForExistence(timeout: 5))
        wallet.tap()
        let customize = app.buttons["walletSettings.customize"]
        XCTAssertTrue(customize.waitForExistence(timeout: 5))
        customize.tap()
        let input = app.textFields["walletCustomize.name"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "Name must receive automatic focus")
        let apply = app.buttons["walletCustomize.apply"]
        let purple = app.buttons["walletCustomize.color.8B36C9"]
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "customize-keyboard-layout"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTAssertTrue(apply.isHittable)
        XCTAssertLessThan(apply.frame.maxY, keyboard.frame.minY, "Apply must remain above the native keyboard")
        XCTAssertTrue(purple.isHittable, "Colors must remain reachable with the keyboard open")
        input.typeText(" Purple")
        let editedName = input.value as? String
        purple.tap()
        XCTAssertTrue(purple.isSelected)
        let hide = app.buttons["keyboard.keyboardDone"]
        XCTAssertTrue(hide.isHittable)
        capture("customize-wallet-keyboard", app)
        hide.tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
        input.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        apply.tap()
        XCTAssertTrue(customize.waitForExistence(timeout: 5), "Apply returns through the native Settings navigator")
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
        customize.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, editedName)
        XCTAssertTrue(purple.isSelected, "The committed color must reopen selected")
    }

    @MainActor func testSettingsNativeNavigationAndLanguageSearch() {
        let app = createWallet()
        defer { app.terminate() }
        app.buttons["home.settings"].tap()
        let wallets = app.buttons["settings.wallets"]
        XCTAssertTrue(wallets.waitForExistence(timeout: 5))
        XCTAssertFalse(settingsBackButton(app).exists, "The root has Close, not Back")
        XCTAssertTrue(app.navigationBars.buttons["settings.lock"].isHittable, "Lock belongs in the root app bar")
        XCTAssertFalse(app.buttons["settings.backup"].exists, "Backup belongs to each wallet's settings")
        wallets.tap()
        let wallet = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.wallet.")).firstMatch
        XCTAssertTrue(wallet.waitForExistence(timeout: 5))
        XCTAssertTrue(settingsBackButton(app).exists)
        XCTAssertFalse(app.buttons["settings.lock"].exists, "Pushed pages keep native Back only")
        wallet.tap()
        let rename = app.buttons["walletSettings.customize"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.tap()
        let input = app.textFields["walletCustomize.name"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        input.typeText(" draft")
        // Gesture-based pop must return one screen, not dismiss Settings or
        // jump to its root. No app-defined gesture or transition can fake this.
        nativeBackSwipe(app)
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        XCTAssertFalse(input.exists)
        settingsBackButton(app).tap()
        XCTAssertTrue(wallet.waitForExistence(timeout: 5))
        nativeBackSwipe(app)
        XCTAssertTrue(wallets.waitForExistence(timeout: 5))

        wallets.tap()
        wallet.tap()
        app.buttons["walletSettings.recovery"].tap()
        XCTAssertTrue(app.buttons["recoveryDisclosure.understand"].waitForExistence(timeout: 5))
        nativeBackSwipe(app)
        XCTAssertTrue(app.buttons["walletSettings.recovery"].waitForExistence(timeout: 5))
        settingsBackButton(app).tap()
        XCTAssertTrue(wallet.waitForExistence(timeout: 5))
        settingsBackButton(app).tap()
        XCTAssertTrue(wallets.waitForExistence(timeout: 5))
        app.buttons["settings.appearance"].tap()
        XCTAssertTrue(app.buttons["settings.appearance.light"].waitForExistence(timeout: 5))
        settingsBackButton(app).tap()
        app.buttons["settings.language"].tap()
        let search = app.searchFields["settings.languageSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertLessThan(search.frame.maxY, app.frame.height * 0.3,
                          "Native language search belongs in the top navigation bar")
        XCTAssertEqual(app.navigationBars.count, 1, "Language must share the Settings navigator")
        search.tap()
        search.typeText("Arabic")
        XCTAssertTrue(app.cells["language.choice.ar"].waitForExistence(timeout: 5))
        app.cells["language.choice.ar"].tap()
        XCTAssertTrue(app.buttons["settings.language"].waitForExistence(timeout: 5))
        XCTAssertTrue(wallets.waitForExistence(timeout: 5))
        XCTAssertFalse(search.exists, "Popping Language must remove its search from Settings")
        // In-app RTL selection must also mirror native Back and its edge swipe.
        let localized = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "المحافظ"), object: wallets)
        XCTAssertEqual(XCTWaiter.wait(for: [localized], timeout: 5), .completed)
        wallets.tap()
        XCTAssertTrue(wallet.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(settingsBackButton(app).frame.midX, app.frame.midX)
        nativeBackSwipe(app, rightToLeft: true)
        XCTAssertTrue(wallets.waitForExistence(timeout: 5))
        app.buttons["options.close"].tap()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 5))
    }

    @MainActor private func settingsBackButton(_ app: XCUIApplication) -> XCUIElement {
        // Native Back owns its accessibility identifier. Do not replace it
        // with an app-defined control just to preserve the old sheet test ID.
        app.navigationBars.buttons.matching(NSPredicate(
            format: "identifier != %@ AND identifier != %@", "options.close", "settings.lock")).firstMatch
    }

    @MainActor private func nativeBackSwipe(_ app: XCUIApplication, rightToLeft: Bool = false) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: rightToLeft ? 0.995 : 0.005, dy: 0.45))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: rightToLeft ? 0.005 : 0.995, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }

    @MainActor func testColdLaunchShowsHomeAndUsableKeypad() {
        let originalAppearance = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = originalAppearance }
        XCUIDevice.shared.appearance = .light
        let app = createWallet()
        app.buttons["home.settings"].tap()
        chooseAppearance("Dark", app: app)
        app.buttons["options.close"].tap()
        app.terminate()
        // Public disposable fixture namespace, never credentials. This permits
        // a focused host video of the exact same cold launch after the test.
        print("OATH_COLD_LAUNCH_SCOPE=\(app.launchArguments[7])")
        app.launch()
        XCTAssertTrue(app.staticTexts["wallet.unlock.title"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["home.settings"].isHittable)
        assertHomeBackdrop()
        XCTAssertLessThan(canvasBrightness(x: 0.985, y: 0.82), 100,
                          "The first lock must use saved Dark even while the system is Light")
        let zero = app.buttons["keypad.digit.0"].frame
        let backspace = app.buttons["keypad.delete"].frame
        XCTAssertGreaterThan(backspace.midX, zero.midX)
        XCTAssertEqual(backspace.midY, zero.midY, accuracy: 1)
        app.buttons["keypad.digit.2"].tap()
        XCTAssertTrue(app.buttons["keypad.delete"].isEnabled)
        app.buttons["keypad.delete"].tap()
        XCTAssertFalse(app.buttons["keypad.delete"].isEnabled)
        capture("cold-launch-home-backdrop-english", app)
        enterPIN(app)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 15))
        backgroundAndReturn(app)
        enterPIN(app)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 15))
        app.terminate()
    }

    @MainActor func testReopeningWithPrivacyPreservesAssetReceiveAndUsableKeypad() {
        let app = createWallet()
        defer { app.terminate() }
        app.buttons["home.settings"].tap()
        app.buttons["settings.security"].tap()
        let privacy = app.switches["security.switcherPrivacy"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 5))
        if privacy.value as? String != "1" { privacy.tap() }
        XCTAssertEqual(privacy.value as? String, "1")
        settingsBackButton(app).tap()
        app.buttons["options.close"].tap()

        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("Ethereum\n")
        let ethereum = app.buttons["home.network.ethereum"]
        XCTAssertTrue(ethereum.waitForExistence(timeout: 10))
        ethereum.tap()
        XCTAssertTrue(app.buttons["asset.receive"].waitForExistence(timeout: 10))
        app.buttons["asset.receive"].tap()
        let copy = app.buttons["receive.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        app.buttons["options.close"].tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5), "Receive must close before testing lock recovery")
        app.buttons["asset.receive"].tap()
        XCTAssertTrue(copy.waitForExistence(timeout: 10))

        backgroundAndReturn(app)
        XCTAssertFalse(copy.isHittable, "Receive must stay protected while locked")
        enterPIN(app)
        XCTAssertTrue(app.staticTexts["wallet.unlock.title"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(copy.isHittable, "The privacy cover must not intercept the restored Receive sheet")
        app.buttons["options.close"].tap()
        let receiveDismissed = copy.waitForNonExistence(timeout: 5)
        if !receiveDismissed {
            let description = app.debugDescription
            print("OATH_RECEIVE_CLOSE_HIERARCHY=\(description)")
            let hierarchy = XCTAttachment(string: description)
            hierarchy.name = "receive-close-after-unlock"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            capture("receive-close-after-unlock", app)
        }
        XCTAssertTrue(receiveDismissed, "Receive must finish dismissing before its asset becomes interactive")
        XCTAssertTrue(app.buttons["asset.receive"].isHittable, "Locking must preserve the asset navigation stack")

        // Also check opening after process termination with the same saved
        // privacy preference, rather than only the background presentation.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["wallet.unlock.title"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["keypad.digit.1"].isHittable)
        enterPIN(app)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["home.settings"].isHittable)
    }

    @MainActor func testUnlockRevealKeepsHomeAndLastOpenedSheet() {
        let app = createWallet()
        defer { app.terminate() }

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["wallet.unlock.title"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["home.settings"].isHittable)
        capture("reveal-cold-home-locked", app)
        enterPIN(app)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["home.settings"].isHittable)
        XCTAssertFalse(app.staticTexts["wallet.unlock.title"].exists)
        capture("reveal-cold-home-unlocked", app)

        app.buttons["home.settings"].tap()
        app.buttons["settings.language"].tap()
        let search = app.searchFields["settings.languageSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Arabic")
        XCTAssertTrue(app.cells["language.choice.ar"].waitForExistence(timeout: 5))
        backgroundAndReturn(app)
        XCTAssertFalse(app.cells["language.choice.ar"].isHittable)
        capture("reveal-retained-sheet-locked", app)
        enterPIN(app)
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        XCTAssertEqual(search.value as? String, "Arabic")
        XCTAssertTrue(app.cells["language.choice.ar"].isHittable)
        XCTAssertFalse(app.staticTexts["wallet.unlock.title"].exists)
        capture("reveal-retained-sheet-unlocked", app)
    }

    @MainActor func testAppearanceChoiceSurvivesSheetsLockAndColdLaunch() {
        let device = XCUIDevice.shared
        let originalAppearance = device.appearance
        defer { device.appearance = originalAppearance }
        device.appearance = .dark
        let app = createWallet()
        app.buttons["home.settings"].tap()
        chooseAppearance("Light", app: app)
        app.buttons["settings.language"].tap()
        XCTAssertTrue(app.searchFields["settings.languageSearch"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(canvasBrightness(x: 0.985, y: 0.6), 200,
                             "An already presented native sheet must follow the Light choice")
        capture("appearance-light-expanded-language-sheet", app)
        backgroundAndReturn(app)
        XCTAssertGreaterThan(canvasBrightness(x: 0.985, y: 0.6), 170,
                             "The lock must keep the chosen light material over the light sheet")
        capture("appearance-light-lock-over-settings", app)
        enterPIN(app)
        XCTAssertTrue(app.searchFields["settings.languageSearch"].waitForExistence(timeout: 10))
        XCTAssertGreaterThan(canvasBrightness(x: 0.985, y: 0.6), 200)
        app.buttons["options.close"].tap()

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["wallet.unlock.title"].waitForExistence(timeout: 15))
        XCTAssertGreaterThan(canvasBrightness(x: 0.985, y: 0.82), 170,
                             "Cold launch must restore Light even while the device is Dark")
        capture("appearance-light-cold-launch", app)
        enterPIN(app)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 15))
        XCTAssertGreaterThan(canvasBrightness(x: 0.985, y: 0.6), 200)
        app.buttons["home.settings"].tap()
        chooseAppearance("Dark", app: app)
        capture("appearance-dark-partial-settings-sheet", app)
        device.appearance = .light
        app.buttons["settings.language"].tap()
        XCTAssertTrue(app.searchFields["settings.languageSearch"].waitForExistence(timeout: 5))
        XCTAssertLessThan(canvasBrightness(x: 0.985, y: 0.6), 80,
                          "Dark must remain selected when the device switches to Light")
        capture("appearance-dark-expanded-language-sheet", app)
        backgroundAndReturn(app)
        XCTAssertLessThan(canvasBrightness(x: 0.985, y: 0.6), 100)
        capture("appearance-dark-lock-over-settings", app)
        enterPIN(app)
        XCTAssertTrue(app.searchFields["settings.languageSearch"].waitForExistence(timeout: 10))
        app.buttons["options.close"].tap()
        capture("appearance-dark-home-surfaces", app)
        app.buttons["home.settings"].tap()
        chooseAppearance("System", app: app)
        app.buttons["options.close"].tap()
        XCTAssertGreaterThan(canvasBrightness(x: 0.985, y: 0.6), 200,
                             "Choosing System must release the explicit Dark override")
        app.terminate()
    }

    @MainActor private func chooseAppearance(_ name: String, app: XCUIApplication) {
        let picker = app.buttons["settings.appearance"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        let option = app.buttons["settings.appearance.\(name.lowercased())"]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
        settingsBackButton(app).tap()
        let committed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", name, name), object: picker)
        XCTAssertEqual(XCTWaiter.wait(for: [committed], timeout: 5), .completed)
    }

    @MainActor func testBackgroundLockPreservesHomeAndOpenLanguageSheet() {
        let app = createWallet()
        let homeAppearance = canvasBrightness(x: 0.985, y: 0.6)

        backgroundAndReturn(app)
        capture("lock-over-live-home", app)
        XCTAssertFalse(app.buttons["home.settings"].isHittable)
        app.swipeDown()
        XCTAssertTrue(app.staticTexts["wallet.unlock.title"].exists, "The lock cannot be swiped away")
        enterPIN(app, digits: [0, 0, 0, 0, 0, 0])
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 8))
        app.alerts.buttons["confirmation.done"].tap()
        XCTAssertTrue(app.staticTexts["wallet.unlock.title"].exists)
        enterPIN(app)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 15))
        XCTAssertEqual(canvasBrightness(x: 0.985, y: 0.6), homeAppearance, accuracy: 12,
                       "The first lock must not recolor the original home screen")
        app.buttons["home.settings"].tap()
        XCTAssertTrue(app.buttons["settings.language"].waitForExistence(timeout: 5))
        app.buttons["settings.language"].tap()
        let search = app.searchFields["settings.languageSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Arabic")
        XCTAssertTrue(app.cells["language.choice.ar"].waitForExistence(timeout: 5))
        let originalAppearance = canvasBrightness()
        backgroundAndReturn(app)
        capture("lock-over-live-language-sheet", app)
        XCTAssertFalse(app.cells["language.choice.ar"].isHittable)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        enterPIN(app)
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        XCTAssertEqual(search.value as? String, "Arabic", "The existing sheet's search must survive locking")
        XCTAssertTrue(app.cells["language.choice.ar"].isHittable)
        XCTAssertEqual(canvasBrightness(), originalAppearance, accuracy: 12,
                       "The lock must not change the presenting sheet's light/dark appearance")
        capture("language-sheet-restored", app)

        // Language selection updates the same retained scene and the overlay's
        // native environment. Verify Arabic text on the next foreground visit.
        app.cells["language.choice.ar"].tap()
        XCTAssertTrue(app.buttons["options.close"].waitForExistence(timeout: 5))
        app.buttons["options.close"].tap()
        backgroundAndReturn(app)
        XCTAssertEqual(app.staticTexts["wallet.unlock.title"].label, "أدخل رمز الدخول")
        for row in 0..<3 {
            let a = app.buttons["keypad.digit.\(row * 3 + 1)"].frame.midX
            let b = app.buttons["keypad.digit.\(row * 3 + 2)"].frame.midX
            let c = app.buttons["keypad.digit.\(row * 3 + 3)"].frame.midX
            XCTAssertLessThan(a, b, "Arabic must keep the standard numeric keypad positions")
            XCTAssertLessThan(b, c)
        }
        capture("lock-arabic", app)
        enterPIN(app)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 15))

        // A terminated process has no live navigation state. It must start with
        // the actual Home beneath the lock, never an empty solid backdrop.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["wallet.unlock.title"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["home.settings"].isHittable)
        assertHomeBackdrop()
        let zero = app.buttons["keypad.digit.0"].frame
        let backspace = app.buttons["keypad.delete"].frame
        XCTAssertGreaterThan(backspace.midX, zero.midX)
        XCTAssertEqual(backspace.midY, zero.midY, accuracy: 1)
        app.buttons["keypad.digit.2"].tap()
        XCTAssertTrue(app.buttons["keypad.delete"].isEnabled)
        app.buttons["keypad.delete"].tap()
        XCTAssertFalse(app.buttons["keypad.delete"].isEnabled)
        capture("cold-launch-home-backdrop", app)
        enterPIN(app)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 15))
        app.terminate()
    }

    @MainActor private func backgroundAndReturn(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(app.staticTexts["wallet.unlock.title"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["keypad.digit.1"].isHittable)
    }

    @MainActor private func enterPIN(_ app: XCUIApplication, digits: [Int] = [2, 9, 4, 8, 1, 6]) {
        for digit in digits { app.buttons["keypad.digit.\(digit)"].tap() }
    }

    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func canvasBrightness(x: CGFloat = 0.9, y: CGFloat = 0.52) -> Double {
        let rgba = canvasPixel(x: x, y: y)
        return Double(Int(rgba[0]) + Int(rgba[1]) + Int(rgba[2])) / 3
    }

    @MainActor private func assertHomeBackdrop() {
        // The header's far edge is nearly charcoal in Dark and cannot reliably
        // distinguish it from the asset canvas. Sample the blue header center,
        // clear of the lock icon/toolbar, in both appearances.
        let upper = canvasPixel(x: 0.5, y: 0.12)
        let lower = canvasPixel(x: 0.04, y: 0.82)
        XCTAssertGreaterThan(Int(upper[2]) - Int(upper[0]), 15,
                             "The blue animated Home must be visible through the native blur on cold launch")
        XCTAssertGreaterThan(abs(Int(upper[2]) - Int(lower[2])) + abs(Int(upper[0]) - Int(lower[0])), 25,
                             "The blur must show Home's header and asset area, not a solid fallback")
    }

    @MainActor private func canvasPixel(x: CGFloat, y: CGFloat) -> [UInt8] {
        // A blank point on the expanded language sheet, above the keyboard.
        // Sample a known RGBA context rather than assuming screenshot byte order.
        let image = XCUIScreen.main.screenshot().image.cgImage!
        let point = CGRect(x: CGFloat(image.width) * x, y: CGFloat(image.height) * y,
                           width: 1, height: 1)
        let pixel = image.cropping(to: point)!
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                                    bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return rgba
    }
}

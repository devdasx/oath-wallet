import XCTest

/// Public BIP-39 fixture in a disposable simulator. No real user's wallet.
@MainActor final class OathHelpCenterScreenshotTests: XCTestCase {
    func testCaptureHelpCenter() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-oath.languagePreference", "en", "-oath.walletTestScope", UUID().uuidString, "-oath-artwork-reduce-motion"]
        app.launch()
        defer { app.terminate() }
        tap(app, "onboarding.importWallet", wait: 25, captureBefore: "welcome")
        let phrase = app.textViews["recovery.phrase"]
        XCTAssertTrue(phrase.waitForExistence(timeout: 12))
        capture("import-recovery")
        phrase.typeText(String(repeating: "abandon ", count: 11) + "about")
        tap(app, "recovery.keyboardDone")
        tap(app, "recovery.import")
        XCTAssertTrue(app.staticTexts["passcode.title"].waitForExistence(timeout: 15))
        capture("set-passcode")
        pin(app)
        let confirm = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Confirm Passcode"), object: app.staticTexts["passcode.title"])
        XCTAssertEqual(XCTWaiter.wait(for: [confirm], timeout: 10), .completed)
        pin(app)
        XCTAssertTrue(app.buttons["walletCustomize.apply"].waitForExistence(timeout: 20))
        if app.buttons["keyboard.keyboardDone"].exists { app.buttons["keyboard.keyboardDone"].tap() }
        capture("customize-wallet")
        tap(app, "walletCustomize.apply")
        XCTAssertTrue(app.buttons["home.receive"].waitForExistence(timeout: 25))
        capture("home")
        tap(app, "home.receive")
        tap(app, "receive.network.ethereum")
        XCTAssertTrue(app.buttons["receive.copy"].waitForExistence(timeout: 15))
        capture("receive-ethereum")
        tap(app, "receive.examples")
        capture("receive-tokens")
        tap(app, "receive.back")
        tap(app, "options.close")
        tap(app, "home.receive")
        tap(app, "receive.network.bitcoin")
        tap(app, "receive.bitcoin.addressType", wait: 30)
        capture("bitcoin-address-types")
        tap(app, "options.close")
        tap(app, "home.settings")
        XCTAssertTrue(app.buttons["settings.wallets"].waitForExistence(timeout: 10))
        capture("settings")
        tap(app, "settings.wallets")
        capture("wallets")
        let wallet = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.wallet.")).firstMatch
        XCTAssertTrue(wallet.waitForExistence(timeout: 10)); wallet.tap()
        capture("wallet-settings")
        tap(app, "walletSettings.recovery")
        capture("recovery-warning")
        back(app); back(app); back(app)
        tap(app, "settings.backup")
        capture("backup-all")
        back(app)
        tap(app, "settings.security")
        XCTAssertTrue(app.buttons["keypad.digit.2"].waitForExistence(timeout: 10)); pin(app)
        XCTAssertTrue(app.switches["security.passcode"].waitForExistence(timeout: 10))
        capture("security")
        back(app)
        tap(app, "settings.appearance")
        capture("appearance")
        tap(app, "settings.appIcon")
        capture("app-icons")
        back(app); back(app)
        tap(app, "settings.contacts")
        tap(app, "contacts.add")
        capture("add-contact")
    }
    private func tap(_ app: XCUIApplication, _ id: String, wait: TimeInterval = 10, captureBefore: String? = nil) {
        let button = app.descendants(matching: .any)[id].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: wait), id)
        for _ in 0..<5 where !button.isHittable { app.swipeUp() }
        if let name = captureBefore { capture(name) }
        button.tap()
    }
    private func back(_ app: XCUIApplication) { app.navigationBars.buttons.firstMatch.tap() }
    private func pin(_ app: XCUIApplication) { for digit in [2, 9, 4, 8, 1, 6] { app.buttons["keypad.digit.\(digit)"].tap() } }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "help-" + name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

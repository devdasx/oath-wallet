import XCTest

/// The driver reinstalls this app on one disposable simulator at the markers.
/// Only a public BIP-39 fixture and test PINs are entered.
final class OathReinstallUITests: XCTestCase {
    @MainActor func testUpdatePreservesWalletAndDeleteReinstallStartsEmpty() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let scope = UUID().uuidString
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-oath.languagePreference", "en", "-oath.walletTestScope", scope,
                               "-oath-artwork-reduce-motion"]
        app.launch()
        importFixture(app, pin: [2, 9, 4, 8, 1, 6], marker: "OATH_REINSTALL_FIRST_ENROLL_READY")
        app.terminate()

        // The host installs over the app without deleting its data container.
        print("OATH_REINSTALL_UPDATE_READY " + scope)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
        print("OATH_REINSTALL_UPDATE_UNLOCK_READY")
        XCTAssertTrue(app.buttons["home.receive"].waitForExistence(timeout: 40),
                      "An ordinary app update must retain the wallet and working biometric credential")
        app.terminate()

        // The host now performs a real simctl uninstall/install, keeping the
        // same scoped Keychain identity to expose any unwanted persistence.
        print("OATH_REINSTALL_DELETE_READY " + scope)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
        XCTAssertTrue(app.buttons["onboarding.createWallet"].waitForExistence(timeout: 20),
                      "Deleting/reinstalling must show welcome, with no unlock screen or old wallet")
        XCTAssertFalse(app.buttons["keypad.biometrics"].exists)
        XCTAssertFalse(app.buttons["home.receive"].exists)
        importFixture(app, pin: [8, 0, 5, 3, 7, 2], marker: "OATH_REINSTALL_FRESH_ENROLL_READY")
        app.terminate()
    }

    @MainActor private func importFixture(_ app: XCUIApplication, pin: [Int], marker: String) {
        XCTAssertTrue(app.buttons["onboarding.importWallet"].waitForExistence(timeout: 15))
        app.buttons["onboarding.importWallet"].tap()
        let phrase = app.textViews["recovery.phrase"]
        XCTAssertTrue(phrase.waitForExistence(timeout: 8))
        phrase.typeText(String(repeating: "abandon ", count: 11) + "about")
        app.buttons["recovery.keyboardDone"].tap()
        app.buttons["recovery.import"].tap()
        XCTAssertTrue(app.staticTexts["passcode.title"].waitForExistence(timeout: 8))
        for digit in pin { app.buttons["keypad.digit.\(digit)"].tap() }
        let confirm = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Confirm Passcode"),
                                                object: app.staticTexts["passcode.title"])
        XCTAssertEqual(XCTWaiter.wait(for: [confirm], timeout: 8), .completed)
        for digit in pin { app.buttons["keypad.digit.\(digit)"].tap() }
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if system.alerts.firstMatch.waitForExistence(timeout: 3) {
            for title in ["Allow", "OK"] where system.alerts.buttons[title].exists {
                system.alerts.buttons[title].tap()
                break
            }
        }
        print(marker)
        app.completeWalletCustomization(timeout: 40)
        XCTAssertTrue(app.buttons["home.receive"].waitForExistence(timeout: 40))
        XCTAssertFalse(app.alerts["Passcode set"].exists)
    }
}

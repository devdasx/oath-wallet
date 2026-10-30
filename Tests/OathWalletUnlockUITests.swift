import XCTest

/// Run only on a disposable simulator with simulated Face ID enrolled. The
/// host supplies a simulated match at each marker; production auth is unchanged.
final class OathWalletUnlockUITests: XCTestCase {
    @MainActor func testAutomaticFaceIDUnlockReachesHomeAfterRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-oath.languagePreference", "en",
                               "-oath.walletTestScope", UUID().uuidString,
                               "-oath-artwork-reduce-motion"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.importWallet"].waitForExistence(timeout: 15))
        app.buttons["onboarding.importWallet"].tap()
        let phrase = app.textViews["recovery.phrase"]
        XCTAssertTrue(phrase.waitForExistence(timeout: 8))
        // Public BIP-39 test vector, never a real wallet.
        phrase.typeText(String(repeating: "abandon ", count: 11) + "about")
        app.buttons["recovery.keyboardDone"].tap()
        app.buttons["recovery.import"].tap()
        XCTAssertTrue(app.staticTexts["passcode.title"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.progressIndicators.firstMatch.exists)
        XCTAssertFalse(app.staticTexts["passcode.notice"].exists)
        XCTAssertFalse(app.buttons["passcode.startOver"].exists)
        enterPIN(app)
        let confirmation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Confirm Passcode"),
            object: app.staticTexts["passcode.title"])
        XCTAssertEqual(XCTWaiter.wait(for: [confirmation], timeout: 8), .completed)
        enterPIN(app)
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if system.alerts.firstMatch.waitForExistence(timeout: 3) {
            for title in ["Allow", "OK"] where system.alerts.buttons[title].exists {
                system.alerts.buttons[title].tap()
                break
            }
        }
        print("OATH_FACE_ID_ENROLLMENT_READY")
        app.completeWalletCustomization(timeout: 40)
        XCTAssertTrue(app.buttons["home.receive"].waitForExistence(timeout: 40))
        XCTAssertFalse(app.alerts["Passcode set"].exists)
        app.terminate()
        app.launch()
        // The automatic system prompt may cover the app's accessibility tree.
        // Do not wait for or touch the manual biometric button before matching.
        print("OATH_FACE_ID_UNLOCK_READY")
        XCTAssertTrue(app.buttons["home.receive"].waitForExistence(timeout: 40),
                      "Face ID must start without a button tap, decrypt the saved wallet and navigate home")
        app.terminate()

    }

    @MainActor private func enterPIN(_ app: XCUIApplication) {
        for digit in [2, 9, 4, 8, 1, 6] { app.buttons["keypad.digit.\(digit)"].tap() }
    }
}

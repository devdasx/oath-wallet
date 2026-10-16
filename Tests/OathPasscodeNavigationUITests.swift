import XCTest

/// Focused regression checks for the native Back action versus interactive pop,
/// and the automatic system biometric request. Use a disposable simulator only.
final class OathPasscodeNavigationUITests: XCTestCase {
    @MainActor
    func test01ConfirmBackAndSwipeHaveDifferentDestinations() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-oath.languagePreference", "en"]
        app.launch()
        openPasscode(in: app)
        enterFixture(in: app)
        expectHeading("Confirm Passcode", in: app)
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        expectHeading("Set a Passcode", in: app)

        enterFixture(in: app)
        expectHeading("Confirm Passcode", in: app)
        let leading = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45))
        let trailing = app.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.45))
        leading.press(forDuration: 0.05, thenDragTo: trailing)
        XCTAssertTrue(app.buttons["onboarding.createWallet"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["onboarding.createWallet"].isHittable)
    }

    @MainActor
    func test02ConfirmationAutomaticallyRequestsFaceIDThenCustomization() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        openPasscode(in: app)
        enterFixture(in: app)
        expectHeading("Confirm Passcode", in: app)
        enterFixture(in: app)

        // Handle Apple's first-use permission if this runtime presents it.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permission = springboard.alerts.firstMatch
        if permission.waitForExistence(timeout: 5) {
            for title in ["Allow", "OK"] where permission.buttons[title].exists {
                permission.buttons[title].tap()
                break
            }
        }
        // The host sends the documented simulated match event after this marker.
        // No production authentication bypass or passcode value is logged.
        print("OATH_BIOMETRY_WAITING_FOR_SIMULATED_MATCH")
        app.completeWalletCustomization(timeout: 45)
        XCTAssertTrue(app.buttons["home.receive"].waitForExistence(timeout: 45),
                      "Successful Face ID must continue to Customize, then Apply opens Home")
        XCTAssertFalse(app.alerts["Passcode set"].exists)
    }

    @MainActor
    private func openPasscode(in app: XCUIApplication) {
        let create = app.buttons["onboarding.createWallet"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        expectHeading("Set a Passcode", in: app)
    }

    @MainActor
    private func expectHeading(_ text: String, in app: XCUIApplication) {
        let heading = app.staticTexts["passcode.title"]
        let condition = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", text), object: heading)
        XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: 8), .completed)
    }

    @MainActor
    private func enterFixture(in app: XCUIApplication) {
        // Disposable test fixture, used only in the isolated simulator.
        for digit in [2, 9, 4, 8, 1, 6] { app.buttons["keypad.digit.\(digit)"].tap() }
    }
}

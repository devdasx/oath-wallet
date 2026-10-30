import XCTest

/// Isolated native wallet peer; the companion tool supplies the real dApp peer.
/// Uses an unfunded public vector and real vault/passcode authorization.
final class OathWalletConnectLiveUITests: XCTestCase {
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testLiveRelayApprovalSigningSwitchRejectDisconnect() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-oath.walletTestScope", UUID().uuidString,
            "-oath.wcRelayFixture", "YES", "-oath.wcVisualFixture", "NO",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-oath.languagePreference", "en"]
        app.launch()
        let approve = app.buttons["walletconnect.approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 60))
        if !approve.isEnabled {
            let acknowledge = app.switches["walletconnect.acknowledge"]
            for _ in 0..<8 {
                if acknowledge.isHittable, acknowledge.frame.maxY < approve.frame.minY - 8 { break }
                app.scrollViews.firstMatch.swipeUp()
            }
            XCTAssertTrue(acknowledge.isHittable)
            acknowledge.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        XCTAssertTrue(approve.isEnabled); capture("live-connection-consent", app); approve.tap()
        // Keep Connected open: the dApp immediately discovers accounts and
        // requests a signature. Requiring Done here masked the stalled login.
        for name in ["message", "typed", "signin", "permit"] {
            let sign = app.buttons["walletconnect.sign"]
            XCTAssertTrue(sign.waitForExistence(timeout: 45), name)
            capture("live-" + name + "-review", app); sign.tap()
            XCTAssertTrue(app.staticTexts["walletconnect.passcode"].waitForExistence(timeout: 20), name)
            if name == "message" { capture("live-passcode", app) }
            for digit in 1...6 { app.buttons["keypad.digit.\(digit)"].tap() }
            closeCompletion(app, name: "live-" + name + "-signed")
        }
        let switchNetwork = app.buttons["walletconnect.sign"]
        XCTAssertTrue(switchNetwork.waitForExistence(timeout: 45))
        capture("live-network-switch", app); switchNetwork.tap()
        closeCompletion(app, name: "live-network-switched")
        let reject = app.buttons["walletconnect.reject"]
        XCTAssertTrue(reject.waitForExistence(timeout: 45)); capture("live-reject-review", app); reject.tap()
        closeCompletion(app, name: "live-rejected")
        let manage = app.buttons["wc.relay.manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 10)); manage.tap()
        let connection = app.buttons["walletconnect.session"].firstMatch
        XCTAssertTrue(connection.waitForExistence(timeout: 10)); connection.tap()
        capture("live-session-details", app)
        app.buttons["walletconnect.openWebsite"].tap()
        let browserDone = app.buttons["Done"].firstMatch
        XCTAssertTrue(browserDone.waitForExistence(timeout: 20))
        let pageLoaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.webViews.staticTexts.allElementsBoundByIndex.contains { $0.label.count > 12 }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pageLoaded], timeout: 30), .completed)
        capture("live-browser", app); browserDone.tap()
        let disconnect = app.buttons["walletconnect.disconnect"]
        for _ in 0..<12 where !disconnect.isHittable { app.swipeUp() }
        XCTAssertTrue(disconnect.isHittable); disconnect.tap()
        let confirm = app.buttons["walletconnect.disconnect.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        capture("live-disconnect-confirmation", app); confirm.tap()
        XCTAssertTrue(app.staticTexts["Disconnected"].waitForExistence(timeout: 20))
        capture("live-disconnected", app)
    }
    @MainActor private func closeCompletion(_ app: XCUIApplication, name: String) {
        let done = app.buttons["walletconnect.state.primary"]
        XCTAssertTrue(done.waitForExistence(timeout: 45), name)
        capture(name, app); done.tap()
    }
}

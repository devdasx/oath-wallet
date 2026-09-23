import XCTest

@MainActor
final class SendSlideUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testFullHorizontalDragsSendExactlyOnce() {
        verifyCompletedDrags(verticalDrift: 0)
    }

    func testFullDragsWithNaturalVerticalDriftSendExactlyOnce() {
        verifyCompletedDrags(verticalDrift: -80)
    }

    func testTapsPartialDragsAndVerticalSwipesDoNotSend() {
        let app = launch(language: "en")
        let slider = app.buttons["sendReviewSlideToSend"]
        slider.tap()
        assertSends(0, in: app)
        drag(slider, isRTL: false, fraction: 0.5)
        assertSends(0, in: app)
        drag(slider, isRTL: false, fraction: 0.1, verticalDrift: -120)
        assertSends(0, in: app)
        drag(slider, isRTL: false)
        assertSends(1, in: app)
    }

    func testHandleTapsAndCancelledSlidesRemainReusableInBothDirections() {
        for language in ["en", "ar"] {
            let app = launch(language: language)
            let slider = app.buttons["sendReviewSlideToSend"]
            let isRTL = language == "ar"

            // A zero-distance recognizer must never turn the draggable handle
            // into a tap-to-send button, including an intentional long press.
            handleStart(slider, isRTL: isRTL).tap()
            assertSends(0, in: app)
            handleStart(slider, isRTL: isRTL).press(forDuration: 0.6)
            assertSends(0, in: app)

            for fraction: CGFloat in [0.35, 0.88] {
                drag(slider, isRTL: isRTL, fraction: fraction)
                assertSends(0, in: app)
                // Restart at the original handle position after the native
                // cancellation spring settles. A stranded thumb cannot pass.
                handleStart(slider, isRTL: isRTL).tap()
                assertSends(0, in: app)
            }
            drag(slider, isRTL: isRTL)
            assertSends(1, in: app)
            app.terminate()
        }
    }

    func testHoldingAtEndWaitsForFingerReleaseBeforeSending() throws {
        for language in ["en", "ar"] {
            let app = launch(language: language)
            drag(app.buttons["sendReviewSlideToSend"], isRTL: language == "ar", holdDuration: 3)
            let releasedAt = Date().timeIntervalSince1970
            assertSends(1, in: app)
            let committedAt = try XCTUnwrap(Double(app.staticTexts["fixture-committed-at"].label))
            XCTAssertLessThan(committedAt - releasedAt, 3,
                              "The native checkmark must complete shortly after release")
            XCTAssertLessThan(releasedAt - committedAt, 2,
                              "Sending must wait for release, not occur during the 3-second endpoint hold")
            app.terminate()
        }
    }

    func testReleaseBelowNinetyPercentCancelsAndAboveItSends() {
        for language in ["en", "ar"] {
            let app = launch(language: language)
            let slider = app.buttons["sendReviewSlideToSend"]
            // Leave room for synthesized-touch pixel rounding. Unit tests cover
            // immediately below, at, and above 90% in both directions.
            drag(slider, isRTL: language == "ar", fraction: 0.88)
            assertSends(0, in: app)
            drag(slider, isRTL: language == "ar", fraction: 0.92)
            assertSends(1, in: app)
            app.terminate()
        }
    }

    func testDisabledDragDoesNotSendAndReenabledControlWorks() {
        let app = launch(language: "en")
        let slider = app.buttons["sendReviewSlideToSend"]
        let toggle = app.switches["fixture-enabled"]
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertFalse(slider.isEnabled)
        drag(slider, isRTL: false)
        assertSends(0, in: app)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(slider.isEnabled)
        drag(slider, isRTL: false)
        assertSends(1, in: app)
    }

    func testCommittedCheckSurvivesAuthenticationAndReactivationInBothDirections() {
        for language in ["en", "ar"] {
            let app = launch(language: language, arguments: ["--fixture-authorization"])
            let slider = app.buttons["sendReviewSlideToSend"]
            drag(slider, isRTL: language == "ar")
            assertSends(1, in: app)
            XCTAssertTrue(slider.isSelected, "Face ID inactivity must retain the completed check")
            XCTAssertFalse(slider.isEnabled)
            XCTAssertEqual(app.staticTexts["fixture-authorization-status"].label, "Authenticating")

            app.buttons["fixture-auth-success"].tap()
            XCTAssertTrue(slider.isSelected, "Successful authorization must retain the check through handoff")
            XCTAssertFalse(slider.isEnabled, "Reactivation must not allow a second confirmation")
            slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            assertSends(1, in: app)

            app.buttons["fixture-auth-cancel"].tap()
            XCTAssertFalse(slider.isSelected)
            waitUntilReady(slider)
            drag(slider, isRTL: language == "ar")
            assertSends(2, in: app)
            XCTAssertTrue(slider.isSelected)
            app.terminate()
        }
    }

    private func verifyCompletedDrags(verticalDrift: CGFloat) {
        for language in ["en", "ar"] {
            let app = launch(language: language)
            let slider = app.buttons["sendReviewSlideToSend"]
            for _ in 0..<3 {
                drag(slider, isRTL: language == "ar", verticalDrift: verticalDrift)
                assertSends(1, in: app)
                // The same completed control must not emit another send.
                slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                assertSends(1, in: app)
                app.buttons["fixture-reset"].tap()
                assertSends(0, in: app)
                waitUntilReady(slider)
            }
            app.terminate()
        }
    }

    private func launch(language: String, arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["sendReviewSlideToSend"].waitForExistence(timeout: 5))
        return app
    }

    private func drag(_ slider: XCUIElement, isRTL: Bool, fraction: CGFloat = 1,
                      verticalDrift: CGFloat = 0, holdDuration: TimeInterval = 0.1) {
        let inset: CGFloat = 32 // 6-point inset + half of the default 52-point handle.
        let travel = (slider.frame.width - inset * 2) * fraction * (isRTL ? -1 : 1)
        let start = handleStart(slider, isRTL: isRTL)
        let end = start.withOffset(CGVector(dx: travel, dy: verticalDrift))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: holdDuration)
    }

    private func waitUntilReady(_ slider: XCUIElement) {
        let returned = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: slider)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 2), .completed,
                       "The slider must become available after the animated return finishes")
    }

    private func handleStart(_ slider: XCUIElement, isRTL: Bool) -> XCUICoordinate {
        let inset: CGFloat = 32
        let startX = isRTL ? slider.frame.width - inset : inset
        return slider.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: startX, dy: slider.frame.height / 2))
    }

    private func assertSends(_ expected: Int, in app: XCUIApplication,
                             file: StaticString = #filePath, line: UInt = #line) {
        let count = app.staticTexts["fixture-send-count"]
        if expected > 0 {
            // XCUITest can consider a native symbol effect idle before its
            // completion callback. Wait for the intentional post-reveal Send.
            let delivered = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@", String(expected)), object: count)
            XCTAssertEqual(XCTWaiter.wait(for: [delivered], timeout: 3), .completed,
                           file: file, line: line)
        }
        XCTAssertEqual(count.label, String(expected), file: file, line: line)
    }
}

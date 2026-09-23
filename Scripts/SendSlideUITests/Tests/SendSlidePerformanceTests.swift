import XCTest

/// Measures real gesture rendering in the wallet-free fixture with native glass
/// and haptics enabled. Counter-only submissions never reach a network.
@MainActor
final class SendSlidePerformanceTests: XCTestCase {
    func testEndpointDragRendering() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ar)", "-AppleLocale", "ar"]
        app.launch()
        let slider = app.buttons["sendReviewSlideToSend"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTHitchMetric(application: app), XCTCPUMetric(application: app)], options: options) {
            for fraction: CGFloat in [0.88, 1, 1] {
                let start = slider.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: slider.frame.width - 32, dy: slider.frame.height / 2))
                let end = start.withOffset(CGVector(dx: -(slider.frame.width - 64) * fraction, dy: 0))
                start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.35)
                XCTAssertEqual(app.staticTexts["fixture-send-count"].label, fraction < 0.9 ? "0" : "1")
                app.buttons["fixture-reset"].tap()
                XCTAssertEqual(app.staticTexts["fixture-send-count"].label, "0")
            }
        }
        app.terminate()
    }
}

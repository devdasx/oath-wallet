import XCTest

@MainActor final class PlacementUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    func testTouchTargetsFollowNativeRefreshOnHomeAndAsset() {
        let app = XCUIApplication()
        app.launchArguments = ["--hit-testing"]
        app.launch()
        checkTouches(app)
        app.buttons["open.asset"].tap()
        checkTouches(app)
    }

    func testPermissionRowTouchTargets() {
        let app = XCUIApplication()
        app.launchArguments = ["--hit-testing", "--system", "--permissions"]
        app.launch()
        checkTouches(app)
    }

    func testSystemRefreshTouchTargets() {
        let app = XCUIApplication()
        app.launchArguments = ["--hit-testing", "--system"]
        app.launch()
        checkTouches(app)
    }

    func testUnmodifiedSwiftUIRefreshTouchBaseline() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OATH_REFRESH_BASELINE"] == "1",
                          "Diagnostic only: use --unmodified-baseline to reproduce the OS ScrollView defect")
        let app = XCUIApplication()
        app.launchArguments = ["--hit-testing", "--system", "--plain-native"]
        app.launch()
        checkTouches(app)
    }

    func testLongAssetListStaysLazy() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["probe.send"].waitForExistence(timeout: 10))
        let rows = Int(app.staticTexts["probe.rows"].label) ?? 0
        XCTAssertGreaterThan(rows, 0)
        XCTAssertLessThan(rows, 50, "A refresh fix must not eagerly build all 500 asset rows")
    }

    private func checkTouches(_ app: XCUIApplication) {
        let send = app.buttons["probe.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate { _, _ in
            app.staticTexts["probe.frames"].label.split(separator: ";").count == 2
        }, evaluatedWith: app)], timeout: 5), .completed, "Native anchors must attach")
        func assertTaps(_ sends: Int, _ receives: Int) {
            XCTAssertEqual(app.staticTexts["probe.taps"].label, "\(sends)|\(receives)")
        }
        func checkGap() {
            for frame in frames() {
                app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: frame.midX, dy: frame.minY - 44)).tap()
            }
        }
        func frames() -> [CGRect] {
            let values = app.staticTexts["probe.frames"].label.split(separator: ";")
            XCTAssertEqual(values.count, 2)
            return values.map {
                let numbers = $0.split(separator: ",").compactMap { Double($0) }
                XCTAssertEqual(numbers.count, 4)
                return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
            }
        }
        func tapVisibleButtons() {
            for frame in frames() {
                app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
            }
        }
        checkGap()
        assertTaps(0, 0)
        tapVisibleButtons()
        assertTaps(1, 1)
        let scroll = app.scrollViews.firstMatch.exists ? app.scrollViews.firstMatch : app.collectionViews.firstMatch
        scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
            .press(forDuration: 0.1,
                   thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)),
                   withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate { _, _ in
            self.status(app).hasPrefix("1|0|started|")
        }, evaluatedWith: app)], timeout: 8), .completed)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "touch-targets-during-refresh"; image.lifetime = .keepAlways; add(image)
        checkGap()
        assertTaps(1, 1)
        tapVisibleButtons()
        assertTaps(2, 2)
        app.buttons["probe.finish"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate { _, _ in
            self.status(app).contains("1|1|succeeded|native|true|")
        }, evaluatedWith: app)], timeout: 10), .completed, "Final state: \(status(app))")
        checkGap()
        assertTaps(2, 2)
        tapVisibleButtons()
        assertTaps(3, 3)
    }

    func testNativePlacementAndRepeatPullOnHomeAndAsset() {
        let app = XCUIApplication()
        app.launch()
        checkPull(app, name: "home", count: 1, outcome: "succeeded")
        checkPull(app, name: "home", count: 2, outcome: "succeeded")
        app.buttons["open.asset"].tap()
        checkPull(app, name: "asset", count: 1, outcome: "succeeded")
    }

    func testFailureReturnsNormally() {
        let app = XCUIApplication()
        app.launchArguments = ["--failure"]
        app.launch()
        checkPull(app, name: "home", count: 1, outcome: "failed")
        XCTAssertTrue(status(app).hasSuffix("|1"))
    }

    func testSystemControlBaseline() {
        let app = XCUIApplication()
        app.launchArguments = ["--system"]
        app.launch()
        checkPull(app, name: "home", count: 1, outcome: "succeeded")
    }

    private func status(_ app: XCUIApplication) -> String { app.staticTexts["probe.status"].label }

    private func checkPull(_ app: XCUIApplication, name: String, count: Int, outcome: String) {
        let scroll = app.descendants(matching: .any).matching(identifier: "probe.\(name)").firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22))
        let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        let began = NSPredicate { _, _ in self.status(app).hasPrefix("\(count)|") }
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: began, evaluatedWith: app)], timeout: 8), .completed)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(name)-\(outcome)-native-refresh"
        attachment.lifetime = .keepAlways
        add(attachment)
        let returned = NSPredicate { _, _ in
            self.status(app).contains("\(count)|\(count)|\(outcome)|native|true|")
        }
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: returned, evaluatedWith: app)], timeout: 10), .completed,
                       "Refresh must stay in the native control, finish once, and return to rest: \(status(app))")
    }
}

import XCTest

@MainActor final class PlacementUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    func testRingUsesNativeControlOnHomeAndAsset() {
        checkNativeControl()
    }

    func testLogoNativeControlBaselineOnHomeAndAsset() {
        let app = XCUIApplication()
        app.launchArguments = ["--ring", "--logo-baseline"]
        app.launch()
        checkPull(app, name: "home", count: 1, outcome: "succeeded")
        app.buttons["open.asset"].tap()
        checkPull(app, name: "asset", count: 1, outcome: "succeeded")
    }

    private func checkNativeControl() {
        let app = XCUIApplication()
        app.launchArguments = ["--ring"]
        app.launch()
        for name in ["home", "asset"] {
            checkPull(app, name: name, count: 1, outcome: "succeeded")
            XCTAssertTrue(app.staticTexts["probe.releaseGeometry"].label.hasSuffix("|false|false"),
                          "The ring must remain inside UIKit's control, which stays active until completion: \(app.staticTexts["probe.releaseGeometry"].label)")
            for button in ["probe.send", "probe.receive"] {
                let frame = app.buttons[button].frame
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
            }
            XCTAssertTrue(app.staticTexts["probe.releaseGeometry"].label.hasSuffix("|1|1|false|false"),
                          "Native return preserves visible button targets")
            if name == "home" { app.buttons["open.asset"].tap() }
        }
    }
    func testReturningToTopRequiresANewPullOnHomeAndAsset() {
        let app = XCUIApplication()
        app.launchArguments = ["--ring", "--gesture-gate"]
        app.launch()
        for name in ["home", "asset"] {
            let scroll = app.collectionViews.firstMatch
            XCTAssertTrue(scroll.waitForExistence(timeout: 10))
            let middle = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            middle.press(forDuration: 0.1, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: -180)),
                         withVelocity: .slow, thenHoldForDuration: 0.2)
            let upper = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
            upper.press(forDuration: 0.1, thenDragTo: upper.withOffset(CGVector(dx: 0, dy: 650)),
                        withVelocity: .slow, thenHoldForDuration: 0.4)
            XCTAssertTrue(status(app).hasPrefix("0|0|idle|"), "Returning from below must not refresh on \(name)")
            let metrics = app.staticTexts["probe.ringMetrics"].label.split(separator: "|")
            XCTAssertEqual(metrics.count, 3)
            XCTAssertEqual(metrics[0], "0", "Navigation emits no refresh haptics")
            XCTAssertEqual(metrics[1], "false", "Navigation must not reveal the pull ring")
            XCTAssertGreaterThan(Double(metrics[2]) ?? 0, 48, "The regression must actually cross the refresh threshold")
            upper.press(forDuration: 0.1, thenDragTo: upper.withOffset(CGVector(dx: 0, dy: 360)),
                        withVelocity: .slow, thenHoldForDuration: 0.4)
            let completed = NSPredicate { _, _ in
                let fields = self.status(app).split(separator: "|")
                return fields.count == 6 && fields[0] == "1" && fields[1] == "1"
                    && fields[2] == "succeeded" && fields[4] == "true"
            }
            XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: completed, evaluatedWith: app)], timeout: 10), .completed,
                           "A separate pull at the top must refresh normally on \(name)")
            if name == "home" { app.buttons["open.asset"].tap() }
        }
    }

    func testProgressRingThresholdOnHomeAndAsset() {
        let app = XCUIApplication()
        app.launchArguments = ["--ring"]
        app.launch()
        for name in ["home", "asset"] {
            let scroll = app.collectionViews.firstMatch
            XCTAssertTrue(scroll.waitForExistence(timeout: 10))
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 35)),
                        withVelocity: .slow, thenHoldForDuration: 0.1)
            XCTAssertTrue(status(app).hasPrefix("0|0|"), "A partial ring must cancel on \(name)")
            for count in 1...2 {
                start.press(forDuration: 0.1,
                    thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72)),
                    withVelocity: .slow, thenHoldForDuration: 0.4)
                let returned = NSPredicate { _, _ in
                    let fields = self.status(app).split(separator: "|")
                    // Work can now finish while the finger is still held down,
                    // before the legacy post-release placement sampler runs.
                    return fields.count == 6 && fields[0] == "\(count)" && fields[1] == "\(count)"
                        && fields[2] == "succeeded" && fields[4] == "true" && fields[5] == "0"
                }
                XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: returned, evaluatedWith: app)], timeout: 10), .completed,
                    "Each pull must start once, finish, and return to rest on \(name): \(status(app))")
                let metrics = app.staticTexts["probe.ringMetrics"].label.split(separator: "|")
                let distance = Double(metrics.first ?? "") ?? -1
                XCTAssertGreaterThanOrEqual(distance, 96, "Do not start before the stroke is full")
                XCTAssertLessThan(distance, 110, "Start at full fill, without waiting for UIKit's later threshold")
                XCTAssertEqual(app.staticTexts["probe.startedWhileDragging"].label, "true",
                               "A filled ring starts while the finger is still down")
                XCTAssertTrue(app.staticTexts["probe.releaseGeometry"].label.hasSuffix("|false"),
                              "Native control owns the indicator throughout refresh")
                XCTAssertEqual(app.staticTexts["probe.ringResult"].label,
                    "true|true|true|false|false|\(count)|\(count)",
                    "Continuous ring loading, blur replacement and exactly one synchronized result feedback are required")
            }
            if name == "home" { app.buttons["open.asset"].tap() }
        }
    }
    func testTimedCheckPrecedesProviderCompletionOnHomeAndAsset() {
        let app = XCUIApplication()
        app.launchArguments = ["--ring", "--timed", "--hold-provider"]
        app.launch()
        for name in ["home", "asset"] {
            let scroll = app.collectionViews.firstMatch
            XCTAssertTrue(scroll.waitForExistence(timeout: 10))
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            start.press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72)),
                        withVelocity: .slow, thenHoldForDuration: 0.4)
            let returned = NSPredicate { _, _ in
                let fields = self.status(app).split(separator: "|")
                return fields.count == 6 && fields[0] == "1" && fields[1] == "0"
                    && fields[2] == "finished" && fields[4] == "true" && fields[5] == "0"
            }
            XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: returned, evaluatedWith: app)], timeout: 10), .completed,
                           "The indicator must finish while the provider is held open on \(name)")
            let metrics = app.staticTexts["probe.ringMetrics"].label.split(separator: "|").compactMap { Double($0) }
            XCTAssertEqual(metrics.count, 4)
            let delay = metrics[2]
            XCTAssertEqual(metrics[3], 3, "A slow full pull emits one tick at each quarter before activation")
            XCTAssertGreaterThanOrEqual(delay, 2.45)
            XCTAssertLessThan(delay, 3.2, "The check must be driven by the 2.5-second timer")
            XCTAssertEqual(app.staticTexts["probe.ringResult"].label, "true|true|true|false|false|1|1")
            app.buttons["probe.finish"].tap()
            let completed = NSPredicate { _, _ in self.status(app).hasPrefix("1|1|finished|") }
            XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: completed, evaluatedWith: app)], timeout: 5), .completed,
                           "Data work must continue after the indicator closes")
            XCTAssertEqual(app.staticTexts["probe.ringResult"].label, "true|true|true|false|false|1|1",
                           "Late provider completion must not replay feedback")
            if name == "home" { app.buttons["open.asset"].tap() }
        }
    }

    func testProgressRingFailureNeverShowsCheck() {
        let app = XCUIApplication()
        app.launchArguments = ["--ring", "--failure"]
        app.launch()
        let scroll = app.collectionViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        start.press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72)),
                    withVelocity: .slow, thenHoldForDuration: 0.4)
        let returned = NSPredicate { _, _ in
            let fields = self.status(app).split(separator: "|")
            return fields.count == 6 && fields[0] == "1" && fields[1] == "1"
                && fields[2] == "failed" && fields[4] == "true" && fields[5] == "1"
        }
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: returned, evaluatedWith: app)], timeout: 10), .completed)
        XCTAssertEqual(app.staticTexts["probe.ringResult"].label, "true|false|false|true|false|1|1")
    }

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

    func testBottomBounceNeverRevealsArtwork() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--system", "--surface-check"]
        app.launch()
        XCTAssertTrue(app.buttons["probe.send"].waitForExistence(timeout: 10))
        let headerPixel = try screenshotPixel(app.screenshot(), app: app,
            point: CGPoint(x: app.frame.midX, y: app.buttons["probe.send"].frame.minY - 15))
        XCTAssertTrue(Int(headerPixel[2]) > Int(headerPixel[0]) + 30,
                      "The real header artwork must remain visible above the opaque body")
        let scroll = app.collectionViews.firstMatch
        scroll.swipeUp(velocity: .fast)
        scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            .press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)),
                   withVelocity: .slow, thenHoldForDuration: 0.5)
        let sample = app.staticTexts["probe.bottomSample"].label.split(separator: "|")
        XCTAssertEqual(sample.count, 2, "The real drag must expose the bottom bounce area")
        guard sample.count == 2 else { return }
        XCTAssertGreaterThan(Int(sample[0]) ?? 0, 50)
        let channels = sample[1].split(separator: ",").compactMap { Int($0) }
        XCTAssertEqual(channels.count, 3)
        XCTAssertTrue(channels.allSatisfy { $0 > 248 }, "Bottom bounce exposed artwork: RGB=\(channels)")
    }

    func testAssetsHeaderHasNoShadowSeamAfterReuse() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--system", "--surface-check"]
        app.launch()
        XCTAssertTrue(app.buttons["probe.send"].waitForExistence(timeout: 10))
        let scroll = app.collectionViews.firstMatch
        for _ in 0..<2 {
            scroll.swipeUp(velocity: .fast)
            scroll.swipeDown(velocity: .fast)
        }
        let first = app.descendants(matching: .any).matching(identifier: "probe.row.0").firstMatch
        XCTAssertTrue(first.exists)
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "assets-header-seam"; attachment.lifetime = .keepAlways; add(attachment)
        for offset: CGFloat in [1, 3, 6, 10] {
            let pixel = try screenshotPixel(shot, app: app, point: CGPoint(x: app.frame.midX, y: first.frame.minY + offset))
            XCTAssertTrue(pixel.allSatisfy { $0 > 252 }, "Assets header shadow leaked into the next cell: RGB=\(pixel)")
        }
    }

    private func screenshotPixel(_ shot: XCUIScreenshot, app: XCUIApplication, point: CGPoint) throws -> [UInt8] {
        let image = try XCTUnwrap(shot.image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        let pixel = try XCTUnwrap(image.cropping(to: CGRect(x: point.x * scale, y: point.y * scale, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Array(rgba.prefix(3))
    }

    func testAssetRowsStayPaintedAfterCellReuse() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--system"]
        app.launch()
        XCTAssertTrue(app.buttons["probe.send"].waitForExistence(timeout: 10))
        let scroll = app.collectionViews.firstMatch
        XCTAssertTrue(scroll.exists)
        // Recycle the header, then return it to the visible cell hierarchy.
        // Accessibility alone misses the bug: covered rows still exist.
        for pass in 0..<4 {
            scroll.swipeUp(velocity: .fast)
            scroll.swipeDown(velocity: .fast)
            let shot = app.screenshot()
            let image = try XCTUnwrap(shot.image.cgImage)
            let scale = CGFloat(image.width) / app.frame.width
            var checked = 0
            for row in 0..<40 {
                let element = app.descendants(matching: .any).matching(identifier: "probe.row.\(row)").firstMatch
                guard element.exists else { continue }
                let rect = element.frame
                guard rect.minY > scroll.frame.minY + 5,
                      rect.maxY < scroll.frame.maxY - 70 else { continue }
                let point = CGPoint(x: rect.minX + 36, y: rect.midY)
                let pixel = try XCTUnwrap(image.cropping(to: CGRect(x: point.x * scale, y: point.y * scale, width: 1, height: 1)))
                var rgba = [UInt8](repeating: 0, count: 4)
                let context = try XCTUnwrap(CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                let visible = rgba[0] > 200 && rgba[1] < 80 && rgba[2] > 200
                if !visible {
                    let attachment = XCTAttachment(screenshot: shot)
                    attachment.name = "covered-asset-row-\(row)-pass-\(pass)"; attachment.lifetime = .keepAlways; add(attachment)
                }
                XCTAssertTrue(visible, "Asset row \(row) is covered after reuse (pass \(pass)); RGB=\(rgba.prefix(3))")
                checked += 1
            }
            XCTAssertGreaterThan(checked, 0, "The scroll regression must inspect visible asset pixels")
        }
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

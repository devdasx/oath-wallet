import XCTest

@MainActor
final class ExactTextLifecycleUITests: XCTestCase {
    func testSystemPrivacyRequestCannotHideIdentifiersWhenPrivacyIsOff() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["System privacy request"].tap()
        assertRendered(app)
        app.buttons["Detail"].tap()
        assertRendered(app, detail: true)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        assertRendered(app, detail: true)
    }

    func testBackgroundAndAuthorizationPreserveRendering() {
        let app = XCUIApplication()
        app.launch()
        assertRendered(app)
        app.buttons["Confirm"].tap()
        app.buttons["Cancel authorization"].tap()
        assertRendered(app)
        for detail in [false, true] {
            if detail { app.buttons["Detail"].tap() }
            assertRendered(app, detail: detail)
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
            app.activate()
            assertRendered(app, detail: detail)
        }
    }

    private func assertRendered(_ app: XCUIApplication, detail: Bool = false) {
        let check = app.buttons[detail ? "Check detail rendering" : "Check rendering"]
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        check.tap()
        let report = app.staticTexts[detail ? "detailRenderReport" : "renderReport"].label
        XCTAssertFalse(report.isEmpty)
        XCTAssertFalse(report.contains("hidden=true"), report)
        XCTAssertFalse(report.contains("layers=0"), report)
        XCTAssertFalse(report.contains("viewport=false"), report)
    }
}

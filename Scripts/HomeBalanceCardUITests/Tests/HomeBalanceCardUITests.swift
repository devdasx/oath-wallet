import XCTest

@MainActor
final class HomeBalanceCardUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testEnglishCardControlsAndLargeBalance() {
        verifyCard(language: "en")
    }

    func testAccessibleArabicCardAndDarkAppearance() {
        verifyCard(language: "ar", largeText: true, dark: true)
    }

    private func verifyCard(language: String, narrow: Bool = false, largeText: Bool = false, dark: Bool = false) {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language]
        app.launchEnvironment = [
            "APERTURE_FIXTURE_LANGUAGE": language,
            "APERTURE_FIXTURE_NARROW": narrow ? "1" : "0",
            "APERTURE_FIXTURE_LARGE_TEXT": largeText ? "1" : "0",
            "APERTURE_FIXTURE_DARK": dark ? "1" : "0"
        ]
        app.launch()
        defer { app.terminate() }

        let amount = app.buttons["wallet-home-balance-card-value"]
        let receive = app.buttons["wallet-home-balance-card-qr"]
        XCTAssertTrue(amount.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(receive.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(amount.isHittable)
        XCTAssertTrue(receive.isHittable)
        XCTAssertGreaterThanOrEqual(receive.frame.width, 44)
        XCTAssertGreaterThanOrEqual(receive.frame.height, 44)
        XCTAssertFalse(amount.frame.intersects(receive.frame))
        XCTAssertEqual(amount.value as? String, "IRR 1.00")
        let originalSize = cardSize(in: app)
        XCTAssertEqual(receive.frame.width, max(44, originalSize.width * 11 / 85.60), accuracy: 1)
        XCTAssertEqual(receive.frame.height, max(44, originalSize.width * 8.3 / 85.60), accuracy: 1)
        XCTAssertLessThan(receive.frame.maxY, amount.frame.minY + 1)
        let cardMinX = (app.frame.width - originalSize.width) / 2
        // The content inset and branding rail leave a 56-point trailing
        // margin. Native layout direction puts that edge on the RTL left.
        let expectedChipCenter = language == "ar"
            ? cardMinX + 56 + receive.frame.width / 2
            : cardMinX + originalSize.width - 56 - receive.frame.width / 2
        XCTAssertEqual(receive.frame.midX, expectedChipCenter, accuracy: 1)
        let containerWidth = narrow ? min(320, app.frame.width) : app.frame.width
        XCTAssertEqual(originalSize.width, min(containerWidth - 40, 440), accuracy: 1)
        XCTAssertGreaterThanOrEqual(originalSize.height, originalSize.width / (1536.0 / 969.0) - 1)

        amount.tap()
        expectLabel("1", on: app.staticTexts["fixture-privacy-count"])
        let hiddenValue = language == "ar" ? "الرصيد مخفي" : "Balance Is Hidden"
        expectValue(hiddenValue, on: amount)
        receive.tap()
        expectLabel("1", on: app.staticTexts["fixture-receive-count"])
        XCTAssertEqual(app.staticTexts["fixture-privacy-count"].label, "1")
        amount.tap()
        expectValue("IRR 1.00", on: amount)

        let large = app.buttons["fixture-large-amount"]
        if !large.isHittable { app.swipeUp() }
        large.tap()
        expectValue("IRR 211,656,098,495.01", on: amount)
        let largeSize = cardSize(in: app)
        XCTAssertEqual(largeSize.width, originalSize.width, accuracy: 1)
        XCTAssertEqual(largeSize.height, originalSize.height, accuracy: 1)
        XCTAssertGreaterThanOrEqual(amount.frame.minX, 20 - 1)
        XCTAssertLessThanOrEqual(amount.frame.maxX, app.frame.width - 20 + 1)
        app.buttons["fixture-small-amount"].tap()
        expectValue("IRR 1.00", on: amount)
    }

    private func cardSize(in app: XCUIApplication) -> CGSize {
        let label = app.staticTexts["fixture-card-size"]
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        let measured = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !label.label.hasPrefix("0.0;") }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [measured], timeout: 5), .completed)
        let components = label.label.split(separator: ";").compactMap { Double($0) }
        XCTAssertEqual(components.count, 2)
        guard components.count == 2 else { return .zero }
        return CGSize(width: components[0], height: components[1])
    }

    private func expectValue(_ value: String, on element: XCUIElement) {
        let condition = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: 5), .completed)
    }

    private func expectLabel(_ label: String, on element: XCUIElement) {
        let condition = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: 5), .completed)
    }
}

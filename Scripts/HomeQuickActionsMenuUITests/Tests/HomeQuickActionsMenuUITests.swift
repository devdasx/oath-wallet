import XCTest

@MainActor
final class HomeQuickActionsMenuUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCurrencySearchSelectionAndRepeatedBackNavigation() {
        verifyCurrencyNavigation(language: "en", title: "Currency")
    }

    func testArabicCurrencyNameSearchAndNativeBackNavigation() {
        verifyCurrencyNavigation(language: "ar", title: "العملة")
    }

    func testEveryOtherShippedRTLLanguageUsesNativePlacement() {
        for (language, title) in [("fa", "ارز"), ("he", "מטבע"),
                                  ("sd", "ڪرنسي"), ("ur", "کرنسی")] {
            verifyCurrencyNavigation(language: language, title: title, repetitions: 1)
        }
    }

    func testLargeTextAndDarkAppearanceKeepSearchAndSelectionUsable() {
        let app = launch(language: "ar", largeText: true, dark: true)
        openMenu(in: app)
        let currency = app.buttons["wallet-home-quick-action-currency"]
        XCTAssertTrue(currency.isHittable)
        currency.tap()
        chooseUSD(in: app)
    }

    func testCurrencyFocusesAutomaticallyFromTopToolbar() {
        let app = launch(language: "ar", topAnchor: true)
        openMenu(in: app)
        app.buttons["wallet-home-quick-action-currency"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        app.typeText("USD")
        XCTAssertEqual(search.value as? String, "USD")
        app.navigationBars["wallet-home-currency-navigation-bar"].buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["wallet-home-quick-action-currency"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    }

    func testBackWithActiveSearchDismissesKeyboardAndRestoresOptions() {
        let app = launch(language: "ar")
        openMenu(in: app)
        app.buttons["wallet-home-quick-action-currency"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("USD")
        let back = app.navigationBars["wallet-home-currency-navigation-bar"].buttons.firstMatch
        XCTAssertTrue(back.isHittable)
        back.tap()
        XCTAssertTrue(app.buttons["wallet-home-quick-action-currency"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.popovers.firstMatch.exists)
        XCTAssertTrue(app.buttons["wallet-home-quick-action-settings"].isHittable)
    }

    func testTopToolbarAnchorSupportsTheSameCurrencyFlow() {
        verifyCurrencyNavigation(language: "en", title: "Currency", topAnchor: true)
    }

    func testTopToolbarArabicSupportsRepeatedBackNavigation() {
        verifyCurrencyNavigation(language: "ar", title: "العملة", topAnchor: true)
    }

    func testTopToolbarAfterRotationKeepsTheCurrencySelectable() {
        let app = launch(language: "en", topAnchor: true)
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        openMenu(in: app)
        app.buttons["wallet-home-quick-action-currency"].tap()
        chooseUSD(in: app)
        XCTAssertTrue(app.buttons["fixture-add-wallet"].isHittable)
        openMenu(in: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.8)).tap()
        XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["wallet-home-quick-actions"].isHittable)
    }

    func testOutsideDismissalAllowsTheOptionsToOpenAgain() {
        let app = launch(language: "en")
        for _ in 0..<3 {
            openMenu(in: app)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).tap()
            XCTAssertTrue(app.buttons["wallet-home-quick-action-currency"].waitForNonExistence(timeout: 5))
        }
        openMenu(in: app)
        app.buttons["wallet-home-quick-action-currency"].tap()
        chooseUSD(in: app)
    }

    func testEveryExternalOptionOpensAfterTheMenuDismisses() {
        for action in ["security", "backupAndKeys", "settings"] {
            let app = launch(language: "en")
            openMenu(in: app)
            let option = app.buttons["wallet-home-quick-action-\(action)"]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            option.tap()
            XCTAssertTrue(app.staticTexts["selected-action"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["wallet-home-quick-action-currency"].exists)
            app.terminate()
        }
    }

    func testSearchAfterRotationKeepsTheCurrencySelectable() {
        let app = launch(language: "en")
        defer { XCUIDevice.shared.orientation = .portrait }
        openMenu(in: app)
        app.buttons["wallet-home-quick-action-currency"].tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 5), .completed, app.debugDescription)
        chooseUSD(in: app)
    }

    private func verifyCurrencyNavigation(language: String, title: String, repetitions: Int = 3, topAnchor: Bool = false) {
        let app = launch(language: language, topAnchor: topAnchor)
        defer { app.terminate() }
        openMenu(in: app)
        let currency = app.buttons["wallet-home-quick-action-currency"]
        let expectedName = Locale(identifier: language).localizedString(forCurrencyCode: "JOD")!
        XCTAssertEqual(currency.value as? String, expectedName)
        let icon = app.images["wallet-home-currency-menu-icon"]
        let rowTitle = app.staticTexts["wallet-home-currency-menu-title"]
        XCTAssertTrue(icon.exists, app.debugDescription)
        XCTAssertTrue(rowTitle.exists, app.debugDescription)
        let isRTL = Locale(identifier: language).language.characterDirection == .rightToLeft
        if isRTL {
            XCTAssertGreaterThan(icon.frame.midX, rowTitle.frame.midX)
        } else {
            XCTAssertLessThan(icon.frame.midX, rowTitle.frame.midX)
        }

        let rootFrame = app.popovers.firstMatch.frame
        XCTAssertEqual(rootFrame.width, 340, accuracy: 1)
        for _ in 0..<repetitions {
            currency.tap()
            XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(app.sheets.count, 0)
            let navigationBar = app.navigationBars["wallet-home-currency-navigation-bar"]
            let back = app.navigationBars["wallet-home-currency-navigation-bar"].buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(back.isHittable, app.debugDescription)
            XCTAssertEqual(back.staticTexts.count, 0, "Back must use the native symbol, not a visible title")
            XCTAssertLessThanOrEqual(back.frame.width, back.frame.height * 1.25,
                                     "Back should retain the native compact icon shape")
            let popover = app.popovers.firstMatch
            XCTAssertTrue(popover.exists)
            let navigationFrame = popover.frame
            XCTAssertEqual(navigationFrame.width, 380, accuracy: 1)
            XCTAssertEqual(navigationFrame.height, 540, accuracy: 1)
            XCTAssertGreaterThanOrEqual(back.frame.minY, popover.frame.minY - 1)
            XCTAssertLessThanOrEqual(back.frame.maxY, popover.frame.maxY + 1)
            XCTAssertTrue(navigationBar.exists)
            XCTAssertGreaterThanOrEqual(navigationBar.frame.minY, popover.frame.minY - 1)
            XCTAssertLessThanOrEqual(navigationBar.frame.maxY, popover.frame.maxY + 1)
            if isRTL {
                XCTAssertGreaterThan(back.frame.midX, navigationFrame.midX)
            } else {
                XCTAssertLessThan(back.frame.midX, navigationFrame.midX)
            }
            back.tap()
            XCTAssertTrue(currency.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.popovers.firstMatch.exists)
            XCTAssertFalse(navigationBar.exists)
            XCTAssertEqual(app.popovers.firstMatch.frame.width, rootFrame.width, accuracy: 1)
            XCTAssertEqual(app.popovers.firstMatch.frame.height, rootFrame.height, accuracy: 1)
            XCTAssertTrue(icon.exists, "Currency icon disappeared on return")
            XCTAssertTrue(app.buttons["wallet-home-quick-action-settings"].isHittable)
        }
        currency.tap()
        chooseUSD(in: app)
    }

    private func launch(
        language: String, largeText: Bool = false, dark: Bool = false, topAnchor: Bool = false
    ) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["APERTURE_FIXTURE_LANGUAGE"] = language
        app.launchEnvironment["APERTURE_FIXTURE_LARGE_TEXT"] = largeText ? "1" : "0"
        app.launchEnvironment["APERTURE_FIXTURE_DARK"] = dark ? "1" : "0"
        app.launchEnvironment["APERTURE_FIXTURE_TOP_ANCHOR"] = topAnchor ? "1" : "0"
        app.launch()
        return app
    }

    private func openMenu(in app: XCUIApplication) {
        let quickActions = app.buttons["wallet-home-quick-actions"]
        XCTAssertTrue(quickActions.waitForExistence(timeout: 5))
        quickActions.tap()
        XCTAssertTrue(app.buttons["wallet-home-quick-action-currency"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["wallet-home-quick-action-currencyConverter"].exists)
    }

    private func chooseUSD(in app: XCUIApplication) {
        let search = app.searchFields.firstMatch
        if !search.exists {
            let searchButton = app.navigationBars["wallet-home-currency-navigation-bar"].buttons["Search"]
            XCTAssertTrue(searchButton.waitForExistence(timeout: 5), app.debugDescription)
            searchButton.tap()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        search.tap()
        search.typeText("USD")
        let choice = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "USD")).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
        choice.tap()
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["selected-currency"].label, "USD")
    }
}

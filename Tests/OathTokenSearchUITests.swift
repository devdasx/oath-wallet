import XCTest

/// Real user input, real network metadata, and the production database on a
/// disposable simulator. Only the public BIP-39 test vector is imported.
@MainActor final class OathTokenSearchUITests: XCTestCase {
    func testSearchReviewAndAddOnEverySupportedTokenNetwork() {
        continueAfterFailure = false
        let app = configuredApp()
        app.launch()
        defer { app.terminate() }
        createFixtureWallet(app)
        for fixture in OathTokenUIFixture.all {
            search(fixture.address, in: app)
            let result = app.buttons["token.result." + fixture.chain]
            XCTAssertTrue(result.waitForExistence(timeout: 60), "Missing live result: \(fixture.chain)")
            reveal(result, in: app.scrollViews.firstMatch)
            XCTAssertTrue(result.isHittable, fixture.chain)
            if fixture.chain == "ethereum" { capture("contract-search-results-english") }
            result.tap()
            verifyDetails(fixture, in: app)
            if ["ethereum", "tron", "solana"].contains(fixture.chain) { capture("token-details-" + fixture.chain) }
            let confirm = app.buttons["token.confirm"]
            reveal(confirm, in: app.scrollViews["options.scrollContent"])
            confirm.tap()
            let done = app.buttons["token.done"]
            XCTAssertTrue(done.waitForExistence(timeout: 15), "Add did not persist: \(fixture.chain)")
            done.tap()
            XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 8))
            search(fixture.address, in: app)
            let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.token.")).firstMatch
            XCTAssertTrue(saved.waitForExistence(timeout: 15), "Saved token missing: \(fixture.chain)")
            XCTAssertFalse(app.buttons["token.result." + fixture.chain].exists, "Saved token must not be offered again")
            print("OATH_TOKEN_UI_PASS \(fixture.chain) \(fixture.symbol) \(fixture.decimals)")
        }
        // A process restart must not lose imported tokens or their decimals.
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["keypad.digit.2"].waitForExistence(timeout: 15))
        enterPIN(app)
        XCTAssertTrue(app.buttons["home.receive"].waitForExistence(timeout: 20))
        for fixture in OathTokenUIFixture.all {
            search(fixture.address, in: app)
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.token.")).firstMatch
                .waitForExistence(timeout: 10), "Token lost after restart: \(fixture.chain)")
        }
    }

    func testArabicContractSearchAndDetails() {
        continueAfterFailure = false
        let app = configuredApp()
        app.launch(); createFixtureWallet(app)
        defer { app.terminate() }
        app.buttons["home.settings"].tap()
        app.buttons["settings.language"].tap()
        let languageSearch = app.searchFields["settings.languageSearch"]
        XCTAssertTrue(languageSearch.waitForExistence(timeout: 8))
        languageSearch.tap(); languageSearch.typeText("Arabic")
        let arabic = app.cells["language.choice.ar"]
        XCTAssertTrue(arabic.waitForExistence(timeout: 5)); arabic.tap()
        XCTAssertTrue(app.buttons["options.close"].waitForExistence(timeout: 5))
        app.buttons["options.close"].tap()
        XCTAssertTrue(app.staticTexts["الرصيد الإجمالي"].waitForExistence(timeout: 8))
        let fixture = OathTokenUIFixture.all.first { $0.chain == "tron" }!
        search(fixture.address, in: app)
        let result = app.buttons["token.result.tron"]
        XCTAssertTrue(result.waitForExistence(timeout: 45))
        reveal(result, in: app.scrollViews.firstMatch)
        capture("contract-search-results-arabic")
        result.tap(); verifyDetails(fixture, in: app)
        let copy = app.buttons["token.copy"]
        reveal(copy, in: app.scrollViews["options.scrollContent"])
        copy.tap()
        XCTAssertTrue(app.buttons["token.confirm"].isHittable)
        capture("token-details-arabic")
        app.buttons["token.confirm"].tap()
        XCTAssertTrue(app.buttons["token.done"].waitForExistence(timeout: 15))
        app.buttons["token.done"].tap()
    }

    private func configuredApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-oath.languagePreference", "en", "-oath.walletTestScope", UUID().uuidString,
            "-oath-artwork-reduce-motion"]
        return app
    }

    private func createFixtureWallet(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["onboarding.importWallet"].waitForExistence(timeout: 20))
        app.buttons["onboarding.importWallet"].tap()
        let phrase = app.textViews["recovery.phrase"]
        XCTAssertTrue(phrase.waitForExistence(timeout: 10))
        phrase.typeText(String(repeating: "abandon ", count: 11) + "about")
        app.buttons["recovery.keyboardDone"].tap()
        app.buttons["recovery.import"].tap()
        XCTAssertTrue(app.staticTexts["passcode.title"].waitForExistence(timeout: 10))
        enterPIN(app)
        let confirm = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Confirm Passcode"),
            object: app.staticTexts["passcode.title"])
        XCTAssertEqual(XCTWaiter.wait(for: [confirm], timeout: 10), .completed)
        enterPIN(app)
        app.completeWalletCustomization()
        XCTAssertTrue(app.buttons["home.receive"].waitForExistence(timeout: 25))
    }

    private func enterPIN(_ app: XCUIApplication) {
        for digit in [2, 9, 4, 8, 1, 6] { app.buttons["keypad.digit.\(digit)"].tap() }
    }

    private func search(_ address: String, in app: XCUIApplication) {
        if !app.searchFields.firstMatch.isHittable {
            let tabs = app.tabBars.firstMatch
            let search = tabs.buttons["Search"].exists ? tabs.buttons["Search"] : tabs.buttons["بحث"]
            search.tap()
        }
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let current = field.value as? String ?? ""
        // UIKit supplies the placeholder as value when the field is empty.
        if !current.isEmpty && current != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(address)
        let hide = app.buttons["keyboard.keyboardDone"]
        if hide.waitForExistence(timeout: 1) { hide.tap() }
        else { field.typeText("\n") }
    }

    private func verifyDetails(_ fixture: OathTokenUIFixture, in app: XCUIApplication) {
        let name = app.staticTexts["token.details.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertEqual(clean(name.label), fixture.name)
        XCTAssertEqual(clean(app.staticTexts["token.details.symbol"].label), fixture.symbol)
        XCTAssertEqual(clean(app.staticTexts["token.details.decimals"].label), String(fixture.decimals))
        XCTAssertEqual(clean(app.staticTexts["token.details.address"].label).lowercased(), fixture.address.lowercased())
        XCTAssertTrue(app.staticTexts["token.details.network"].exists)
        XCTAssertTrue(app.staticTexts["token.details.standard"].exists)
    }

    private func clean(_ value: String) -> String {
        value.filter { !["\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}"].contains(String($0)) }
    }

    private func reveal(_ element: XCUIElement, in scroll: XCUIElement) {
        for _ in 0..<8 where !element.isHittable { scroll.swipeUp(velocity: .slow) }
    }

    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
}

import XCTest

/// Real user input, real network metadata, and the production database on a
/// disposable simulator. Only the public BIP-39 test vector is imported.
@MainActor final class OathTokenSearchUITests: XCTestCase {
    /// Exercise the exact three user entry points. A discovered row must save
    /// without a review sheet, then open the normal destination for that entry.
    func testUSDTDiscoveryInSendReceiveAndHomeSearch() {
        continueAfterFailure = false
        let app = configuredApp()
        app.launch()
        defer { app.terminate() }
        createFixtureWallet(app)

        var selectedIDs: [String] = []
        for entry in ["home.send", "home.receive"] {
            app.buttons[entry].tap()
            let field = app.searchFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 10), entry)
            field.tap(); field.typeText("Usdt")
            let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "token.result.")).firstMatch
            XCTAssertTrue(first.waitForExistence(timeout: 15))
            XCTAssertFalse(app.staticTexts["Tokens found"].exists)
            XCTAssertFalse(app.staticTexts["Choose a network to review and add this token to your wallet."].exists)
            capture("unified-search-" + entry)
            // Public fixture addresses can receive tokens between runs. Pick
            // an actually untracked result, not a symbol assumed to be absent.
            selectedIDs.append(String(first.identifier.dropFirst("token.result.".count)))
            XCTAssertTrue(first.isHittable); first.tap()
            if entry == "home.send" {
                XCTAssertTrue(app.textFields["send.address"].waitForExistence(timeout: 20), "Direct selection must open recipient entry")
            } else {
                XCTAssertTrue(app.descendants(matching: .any)["receive.qr"].waitForExistence(timeout: 20), "Direct selection must open the real receive QR")
            }
            XCTAssertFalse(app.buttons["token.confirm"].exists)
            returnToHome(app)
        }
        // Both modal selections must already be normal saved rows in Search.
        search("Usdt", in: app)
        for identity in selectedIDs {
            XCTAssertTrue(app.buttons["home.token." + identity].waitForExistence(timeout: 15))
        }
        capture("unified-search-saved-and-discovered")
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "token.result.")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        let identity = String(result.identifier.dropFirst("token.result.".count))
        // Dismiss the keyboard before reaching the first remaining catalog row.
        XCTAssertTrue(result.isHittable); result.tap()
        XCTAssertTrue(app.buttons["asset.receive"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["token.confirm"].exists)
        returnToHome(app)
        search("Usdt", in: app)
        XCTAssertTrue(app.buttons["home.token." + identity].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["token.result." + identity].exists)
        capture("unified-search-saved-token")
    }

    func testSearchAndDirectAddOnEverySupportedTokenNetwork() {
        continueAfterFailure = false
        let app = configuredApp()
        app.launch()
        defer { app.terminate() }
        createFixtureWallet(app)
        for fixture in OathTokenUIFixture.all {
            search(fixture.address, in: app)
            let result = discovered(fixture, in: app)
            XCTAssertTrue(result.waitForExistence(timeout: 60), "Missing live result: \(fixture.chain)")
            result.tap()
            XCTAssertTrue(app.buttons["asset.receive"].waitForExistence(timeout: 30), fixture.chain)
            XCTAssertFalse(app.buttons["token.confirm"].exists)
            returnToHome(app)
            search(fixture.address, in: app)
            let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.token.")).firstMatch
            XCTAssertTrue(saved.waitForExistence(timeout: 15), "Saved token missing: \(fixture.chain)")
            XCTAssertFalse(discovered(fixture, in: app).exists)
        }
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

    func testArabicContractSearchAndDirectAdd() {
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
        let result = discovered(fixture, in: app)
        XCTAssertTrue(result.waitForExistence(timeout: 45))
        capture("unified-search-arabic")
        result.tap()
        XCTAssertTrue(app.buttons["asset.receive"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["token.confirm"].exists)
    }

    private func discovered(_ fixture: OathTokenUIFixture, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "token.result." + fixture.chain + ":")).firstMatch
    }

    private func returnToHome(_ app: XCUIApplication) {
        for _ in 0..<6 where !app.buttons["home.receive"].isHittable {
            if app.buttons["multisig.gotIt"].exists { app.buttons["multisig.gotIt"].tap(); continue }
            let close = app.buttons.matching(NSPredicate(format: "label == 'Close' OR label == 'Cancel' OR label == 'Cancel Search' OR label == 'Back'")).firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 8)); close.tap()
        }
        let home = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.buttons["home.receive"])
        XCTAssertEqual(XCTWaiter.wait(for: [home], timeout: 8), .completed)
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
        // The system toolbar can expose its localized title instead of the
        // SwiftUI identifier on newer iOS releases.
        let importAction = app.buttons["recovery.import"].exists ? app.buttons["recovery.import"] : app.buttons["Import"]
        importAction.tap()
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

    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
}

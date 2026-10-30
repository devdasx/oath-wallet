import XCTest

/// Small runtime regression for the new push beneath Home's native search host.
/// The fixture is a public BIP-39 vector, stored only in a disposable test scope.
@MainActor final class OathAssetDetailUITests: XCTestCase {
    func testAssetPushBackSearchAndArabicInformationSheet() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-oath.languagePreference", "en",
            "-oath.walletTestScope", UUID().uuidString, "-oath-artwork-reduce-motion"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["onboarding.importWallet"].waitForExistence(timeout: 20))
        app.buttons["onboarding.importWallet"].tap()
        let phrase = app.textViews["recovery.phrase"]
        XCTAssertTrue(phrase.waitForExistence(timeout: 10))
        phrase.typeText(String(repeating: "abandon ", count: 11) + "about")
        app.buttons["recovery.keyboardDone"].tap()
        app.buttons["recovery.import"].tap()
        XCTAssertTrue(app.staticTexts["passcode.title"].waitForExistence(timeout: 10))
        pin(app)
        let confirm = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Confirm Passcode"), object: app.staticTexts["passcode.title"])
        XCTAssertEqual(XCTWaiter.wait(for: [confirm], timeout: 10), .completed)
        pin(app); app.completeWalletCustomization()
        XCTAssertTrue(app.buttons["home.receive"].waitForExistence(timeout: 20))

        app.tabBars.buttons["Search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Ethereum\n")
        let ethereum = app.buttons["home.network.ethereum"]
        XCTAssertTrue(ethereum.waitForExistence(timeout: 10)); ethereum.tap()
        let balance = app.staticTexts["asset.balance"]
        XCTAssertTrue(balance.waitForExistence(timeout: 10))
        XCTAssertTrue(balance.label.contains("0.0000"))
        XCTAssertFalse(app.searchFields.firstMatch.isHittable, "Home's search toolbar must not leak into the asset screen")
        XCTAssertTrue(app.buttons["asset.receive"].isHittable)
        XCTAssertTrue(app.staticTexts["asset.price"].waitForExistence(timeout: 30))
        capture("asset-wallet-identity-english")
        XCTAssertTrue(app.buttons["asset.chartToggle"].waitForExistence(timeout: 30))
        app.buttons["asset.chartToggle"].tap()
        XCTAssertTrue(app.otherElements["asset.chart"].waitForExistence(timeout: 20))
        app.buttons["asset.receive"].tap()
        XCTAssertTrue(app.buttons["receive.copy"].waitForExistence(timeout: 10))
        app.buttons["options.close"].tap()
        app.buttons["asset.information"].tap()
        XCTAssertTrue(app.staticTexts["asset.info.value.token.network"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["asset.info.value.token.decimals"].label, "18")
        app.buttons["options.close"].tap()
        back(app).tap()
        XCTAssertTrue(app.buttons["home.network.ethereum"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "Ethereum")
        let cancel = app.buttons["Cancel"]
        if cancel.exists { cancel.tap() }
        app.tabBars.buttons["Wallet"].tap()
        app.buttons["home.settings"].tap()
        app.buttons["settings.language"].tap()
        let languageSearch = app.searchFields["settings.languageSearch"]
        XCTAssertTrue(languageSearch.waitForExistence(timeout: 8))
        languageSearch.tap(); languageSearch.typeText("Arabic")
        app.cells["language.choice.ar"].tap()
        app.buttons["options.close"].tap()
        let ethRTL = app.buttons["home.network.ethereum"]
        XCTAssertTrue(ethRTL.waitForExistence(timeout: 10)); ethRTL.tap()
        XCTAssertTrue(app.staticTexts["asset.balance"].waitForExistence(timeout: 10))
        let rtlBack = back(app)
        XCTAssertGreaterThan(rtlBack.frame.midX, app.frame.midX, "Native back control must mirror in RTL")
        capture("asset-wallet-identity-arabic")
        app.buttons["asset.information"].tap()
        XCTAssertTrue(app.staticTexts["معلومات الأصل"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["asset.info.value.token.network"].waitForExistence(timeout: 10))
        capture("asset-information-arabic")
        app.buttons["options.close"].tap()
        back(app).tap()
        XCTAssertTrue(app.buttons["home.receive"].waitForExistence(timeout: 8))
    }
    private func back(_ app: XCUIApplication) -> XCUIElement {
        app.navigationBars.buttons.matching(NSPredicate(format: "identifier != %@", "asset.information")).firstMatch
    }
    private func pin(_ app: XCUIApplication) {
        for digit in [2, 9, 4, 8, 1, 6] { app.buttons["keypad.digit.\(digit)"].tap() }
    }
    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
}

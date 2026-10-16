import XCTest

/// Production view layouts with public fixtures. These tests do not prove relay
/// approval, authentication, chain submission or confirmation.
final class OathWalletConnectVisualUITests: XCTestCase {
    @MainActor private func launch(arabic: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-oath.walletTestScope", "walletconnect-visual-tests", "-oath.wcVisualFixture", "YES",
            "-AppleLanguages", arabic ? "(ar)" : "(en)", "-AppleLocale", arabic ? "ar_PS" : "en_US",
            "-oath.languagePreference", arabic ? "ar" : "en", "-oath.wcFixtureDark", arabic ? "YES" : "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["wc.fixture.connect"].waitForExistence(timeout: 20))
        return app
    }
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    @MainActor private func open(_ state: String, _ app: XCUIApplication) {
        let button = app.buttons["wc.fixture." + state]
        for _ in 0..<8 where !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.isHittable, state); button.tap()
        XCTAssertTrue(app.buttons["wc.fixture.close"].waitForExistence(timeout: 5), state)
    }
    @MainActor private func back(_ app: XCUIApplication) {
        let button = app.navigationBars.buttons["BackButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap()
    }
    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication, footer: String) {
        let primary = app.buttons[footer]
        for _ in 0..<8 {
            if element.exists, element.isHittable, element.frame.maxY < primary.frame.minY - 8 { return }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }
    @MainActor func test01ConsentNativeNavigationAndActions() {
        let app = launch()
        open("connect", app); capture("01-connect", app)
        let approve = app.buttons["walletconnect.approve"]
        XCTAssertTrue(approve.isEnabled)
        app.buttons["walletconnect.wallet"].tap()
        XCTAssertTrue(app.buttons["walletconnect.chooseWallet.imported"].waitForExistence(timeout: 5))
        app.buttons["walletconnect.chooseWallet.imported"].tap(); capture("02-wallets", app); back(app)
        XCTAssertTrue(app.buttons["walletconnect.wallet"].label.contains("Imported Wallet"))
        app.buttons["walletconnect.networks"].tap()
        let required = app.buttons["walletconnect.network.eip155:1"]
        let optional = app.buttons["walletconnect.network.eip155:42161"]
        XCTAssertFalse(required.isEnabled); XCTAssertTrue(optional.isEnabled)
        optional.tap(); capture("03-networks", app); back(app)
        XCTAssertFalse(app.buttons["walletconnect.networks"].label.contains("Arbitrum"))
        app.buttons["walletconnect.permissions"].tap(); capture("04-access", app)
        app.buttons["walletconnect.methods"].tap(); capture("05-methodsdetail", app)
        XCTAssertTrue(app.staticTexts["eth_signTypedData_v4"].exists)
        back(app); back(app)
        app.buttons["walletconnect.identity"].tap(); capture("06-identity", app); back(app)
        approve.tap(); capture("07-connected", app)
        XCTAssertTrue(app.buttons["walletconnect.state.primary"].exists)
        app.buttons["wc.fixture.close"].tap()
        open("unverified", app)
        XCTAssertFalse(app.buttons["walletconnect.approve"].isEnabled)
        let acknowledge = app.switches["walletconnect.acknowledge"]
        reveal(acknowledge, app: app, footer: "walletconnect.approve")
        capture("08-unverified-before-consent", app)
        acknowledge.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: app.buttons["walletconnect.approve"])
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["walletconnect.approve"].isEnabled)
        capture("08-unverified-acknowledged", app)
    }
    @MainActor func test02ImplementedReviewStatesAndDetails() {
        let app = launch()
        for state in ["blocked", "unsupported", "message", "signin", "typed", "permit", "permit2", "connected", "signed", "signedTx", "expired", "changed", "offline", "failed", "disconnected", "pairing"] {
            open(state, app); capture("state-" + state, app)
            if state == "blocked" || state == "unsupported" {
                XCTAssertFalse(app.buttons["walletconnect.approve"].isEnabled)
            }
            if state == "message" || state == "signin" {
                let details = app.buttons["walletconnect.message.details"]
                reveal(details, app: app, footer: "wc.fixture.sign")
                XCTAssertTrue(details.isHittable); details.tap(); capture(state + "-full", app); back(app)
            }
            if ["typed", "permit", "permit2"].contains(state) {
                let fields = app.buttons["walletconnect.typed.fields"]
                reveal(fields, app: app, footer: "wc.fixture.sign")
                XCTAssertTrue(fields.isHittable); fields.tap(); capture(state + "-fields", app); back(app)
                let help = app.buttons["walletconnect.signature.help"]
                reveal(help, app: app, footer: "wc.fixture.sign")
                help.tap(); capture(state + "-help", app); back(app)
            }
            app.buttons["wc.fixture.close"].tap()
        }
    }
    @MainActor func test03ArabicDarkConsentAndPermit() {
        let app = launch(arabic: true)
        open("connect", app); capture("ar-dark-connect", app)
        app.buttons["walletconnect.networks"].tap(); capture("ar-dark-networks", app); back(app)
        app.buttons["wc.fixture.close"].tap()
        open("permit", app); capture("ar-dark-permit", app)
        let fields = app.buttons["walletconnect.typed.fields"]
        for _ in 0..<8 where !fields.isHittable { app.swipeUp() }
        XCTAssertTrue(fields.isHittable); fields.tap(); capture("ar-dark-permit-fields", app)
    }
    @MainActor func test04TransactionReviewsAndNetworkStates() {
        let app = launch()
        for state in ["send", "approve", "swap", "nft", "contract", "pending", "success", "transactionFailed", "gas", "simulation", "submitting"] {
            open(state, app); capture("state-" + state, app)
            if ["send", "approve", "swap", "nft", "contract"].contains(state) {
                for detail in ["recipient", "fees", "data"] {
                    let row = app.buttons["walletconnect.transaction." + detail]
                    reveal(row, app: app, footer: "wc.fixture.sign"); row.tap(); capture(state + "-" + detail, app); back(app)
                }
                if state == "approve" {
                    app.scrollViews.firstMatch.swipeDown()
                    let row = app.buttons["walletconnect.transaction.limit"]
                    reveal(row, app: app, footer: "wc.fixture.sign"); row.tap(); capture("approval-limit", app)
                    app.switches["walletconnect.limit.unlimited"].tap()
                    let input = app.textFields["walletconnect.limit.input"]
                    input.tap(); input.typeText(XCUIKeyboardKey.delete.rawValue + "1.25")
                    let save = app.buttons["walletconnect.limit.save"]
                    XCTAssertTrue(save.isEnabled); save.tap()
                    XCTAssertTrue(app.staticTexts["1.25"].waitForExistence(timeout: 5))
                    capture("approval-edited-limit", app)
                }
                if state == "swap" {
                    let row = app.buttons["walletconnect.transaction.swapDetails"]
                    app.scrollViews.firstMatch.swipeDown()
                    reveal(row, app: app, footer: "wc.fixture.sign"); row.tap(); capture("swap-details", app); back(app)
                }
            }
            if ["pending", "success", "transactionFailed"].contains(state) {
                let row = app.buttons["walletconnect.transaction.details"]
                for _ in 0..<5 where !row.isHittable { app.swipeUp() }
                row.tap(); capture(state + "-details", app); back(app)
            }
            if state == "gas" {
                app.buttons["walletconnect.gas.receive"].tap(); capture("receive-gas", app); back(app)
            }
            app.buttons["wc.fixture.close"].tap()
        }
    }
    @MainActor func test05ThorchainAndAdditionalStates() {
        let app = launch()
        for state in ["thor", "deposit", "networkSwitch", "rejected", "approvalPending", "approvalDone", "sent"] {
            open(state, app); capture("state-" + state, app)
            if state == "thor" || state == "deposit" {
                let details = app.buttons["walletconnect.thor.details"]
                reveal(details, app: app, footer: "wc.fixture.sign")
                details.tap(); capture(state + "-details", app); back(app)
            }
            app.buttons["wc.fixture.close"].tap()
        }
        app.terminate()
        let fresh = launch()
        open("unverified", fresh)
        let identity = fresh.buttons["walletconnect.identity"]
        reveal(identity, app: fresh, footer: "walletconnect.approve")
        identity.tap(); capture("identity-unknown", fresh)
    }
    @MainActor func test06UnsupportedCapabilitiesCannotApprove() {
        let app = launch()
        for (state, method) in [("networkAdd", "wallet_addEthereumChain"), ("batch", "wallet_sendCalls")] {
            open(state, app)
            XCTAssertFalse(app.buttons["walletconnect.approve"].isEnabled)
            let row = app.buttons["walletconnect.unavailable." + method]
            reveal(row, app: app, footer: "walletconnect.approve")
            row.tap(); capture("state-" + state, app)
            XCTAssertTrue(app.staticTexts[method].exists)
            back(app)
            app.buttons["wc.fixture.close"].tap()
        }
    }
    @MainActor func test07CrossChainReviewAndExactMemo() {
        let app = launch()
        open("crossSwap", app); capture("state-crossSwap", app)
        let row = app.buttons["walletconnect.thor.swapDetails"]
        reveal(row, app: app, footer: "wc.fixture.sign"); row.tap()
        capture("crossSwap-details", app)
        XCTAssertTrue(app.staticTexts["Ethereum"].exists)
        XCTAssertTrue(app.staticTexts["0.0006 ETH"].exists)
        back(app)
        let document = app.buttons["walletconnect.thor.details"]
        reveal(document, app: app, footer: "wc.fixture.sign"); document.tap()
        capture("crossSwap-document", app)
    }
    @MainActor func test08SwapProgressAndApprovalOutcomes() {
        let app = launch()
        open("approvalPending", app)
        XCTAssertTrue(app.staticTexts["Approval submitted"].exists)
        capture("state-approvalPending", app); app.buttons["wc.fixture.close"].tap()
        open("approvalDone", app)
        XCTAssertTrue(app.staticTexts["Approval transaction confirmed"].exists)
        capture("state-approvalDone", app); app.buttons["wc.fixture.close"].tap()
        open("crossPending", app)
        XCTAssertTrue(app.staticTexts["THORChain deposit"].exists)
        XCTAssertTrue(app.staticTexts["Swap execution"].exists)
        XCTAssertFalse(app.staticTexts["Destination transfer observed"].exists)
        capture("state-crossPending", app)
    }

}

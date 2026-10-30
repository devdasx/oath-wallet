import XCTest

@MainActor final class NavigationUITests: XCTestCase {
    func testSwitchWalletDiscardsReceiptsButSameWalletRetainsNavigation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        func tab(_ name: String) {
            let button = app.tabBars.buttons[name]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            button.tap()
        }
        func openHistory(search: Bool) {
            tab("History")
            if search { tab("Search") }
        }
        func assertLabel(_ identifier: String, _ label: String) {
            let element = app.staticTexts[identifier]
            let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", label), object: element)
            XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed)
        }
        for search in [false, true] {
            openHistory(search: search)
            assertLabel("history.wallet", "Wallet 1 history")
            app.buttons["transaction.row"].tap()
            assertLabel("receipt", "Wallet 1 receipt")

            tab("Wallet")
            app.buttons["refresh.wallet"].tap()
            openHistory(search: search)
            assertLabel("receipt", "Wallet 1 receipt")

            tab("Wallet")
            app.buttons["switch.wallet"].tap()
            assertLabel("active.wallet", "Wallet 2")
            openHistory(search: search)
            assertLabel("history.wallet", "Wallet 2 history")
            XCTAssertFalse(app.staticTexts["receipt"].exists, "A different wallet must start at its own History root")
            app.buttons["transaction.row"].tap()
            assertLabel("receipt", "Wallet 2 receipt")

            tab("Wallet")
            app.buttons["switch.wallet"].tap()
            openHistory(search: search)
            assertLabel("history.wallet", "Wallet 1 history")
            XCTAssertFalse(app.staticTexts["receipt"].exists, "Switching back must not resurrect either old receipt")
            tab("Wallet")
        }
    }
}

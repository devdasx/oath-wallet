import XCTest

extension XCUIApplication {
    /// Setup and Face ID now finish at the real shared customization page.
    /// Tests that need Home must explicitly apply its initial choices.
    @MainActor func completeWalletCustomization(timeout: TimeInterval = 20) {
        let apply = buttons["walletCustomize.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: timeout))
        XCTAssertTrue(textFields["walletCustomize.name"].exists)
        XCTAssertTrue(apply.isHittable)
        apply.tap()
    }
}

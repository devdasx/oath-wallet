import XCTest

@MainActor
final class HomeAssetPinUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testPinAndUnpinFinishSwipeBeforeNativeSectionMove() {
        verifySwipeSequence(rtl: false, reduceMotion: false)
    }

    func testRTLPinAndUnpinFinishSwipeBeforeNativeSectionMove() {
        verifySwipeSequence(rtl: true, reduceMotion: false)
    }

    func testReduceMotionKeepsSwipeAndPinCorrect() {
        verifySwipeSequence(rtl: false, reduceMotion: true)
    }

    private func verifySwipeSequence(rtl: Bool, reduceMotion: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", rtl ? "(ar)" : "(en)",
                               "-AppleLocale", rtl ? "ar" : "en_US"]
        if reduceMotion { app.launchArguments.append("--reduce-motion") }
        app.launch()
        // Existing pinned group; then all pinned; then remove the pinned group;
        // then recreate it. Both directions use real native swipe buttons.
        let changes = [(0, true), (2, true), (3, true), (0, false),
                       (1, false), (2, false), (3, false), (2, true)]
        var pinnedCount = 1
        for (id, pinned) in changes {
            let nextCount = pinnedCount + (pinned ? 1 : -1)
            let keepsBothSections = (1...3).contains(pinnedCount) && (1...3).contains(nextCount)
            app.buttons["Record"].tap()
            let row = app.otherElements["asset-\(id)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            if rtl { row.swipeLeft() } else { row.swipeRight() }
            let button = app.buttons[pinned ? "home.asset.pin" : "home.asset.unpin"]
            XCTAssertTrue(button.waitForExistence(timeout: 3))
            button.tap()
            let predicate = NSPredicate(format: "value == %@", String(pinned))
            expectation(for: predicate, evaluatedWith: row)
            waitForExpectations(timeout: 5)
            XCTAssertTrue(button.waitForNonExistence(timeout: 3))
            app.buttons["Report"].tap()
            let report = app.staticTexts["report"].label
            XCTAssertTrue(report.contains("commits=1;swiped=false;horizontal=true;outside=0;diagonal=0"), report)
            // Section insertion/deletion uses UIKit's own transition and need
            // not contain intermediate vertical positions for the selected cell.
            // Require a measured native move when both sections remain present.
            if reduceMotion || keepsBothSections {
                XCTAssertTrue(report.contains("animated=\(!reduceMotion)"), report)
            }
            pinnedCount = nextCount
        }
        app.terminate()
    }
}

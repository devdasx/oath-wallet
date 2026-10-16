import XCTest

final class OathLocalizationUITests: XCTestCase {
    @MainActor override func tearDown() async throws {
        if let run = testRun, run.totalFailureCount > 0 {
            let app = XCUIApplication()
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Language-switch failure hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            attach("Language-switch failure", app)
        }
    }

    @MainActor func testLanguageSwitchingPreservesNativeNavigation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.moreOptions"].waitForExistence(timeout: 10))
        // Establish the starting language using the real preference UI, so
        // retrying this test never relies on a reset of the app's stored data.
        if app.buttons["onboarding.createWallet"].label != "Create a new wallet" {
            chooseLanguage("English", in: app)
            app.buttons["Close"].firstMatch.tap()
        }
        chooseLanguage("العربية", in: app)
        XCTAssertTrue(app.navigationBars.staticTexts["المزيد من الخيارات"].exists)
        XCTAssertLessThan(app.buttons["options.close"].frame.midX, app.frame.midX,
                          "The sheet's trailing Close control mirrors in Arabic")
        XCTAssertTrue(app.buttons["onboarding.restoreICloud"].waitForExistence(timeout: 5))
        attach("Arabic options", app)
        app.buttons["onboarding.restoreICloud"].tap()
        XCTAssertTrue(app.staticTexts["لا توجد نسخ احتياطية بعد"].waitForExistence(timeout: 5))
        attach("Arabic iCloud empty state", app)
        app.buttons["icloud.backToOptions"].tap()
        app.buttons["إغلاق"].firstMatch.tap()

        let create = app.buttons["onboarding.createWallet"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertEqual(create.label, "إنشاء محفظة جديدة")
        attach("Arabic welcome", app)
        create.tap()
        expectHeading("تعيين رمز الدخول", in: app)
        attach("Arabic passcode", app)
        for digit in [2, 9, 4, 8, 1, 6] { app.buttons["keypad.digit.\(digit)"].tap() }
        expectHeading("تأكيد رمز الدخول", in: app)
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertGreaterThan(back.frame.midX, app.frame.midX)
        back.tap()
        expectHeading("تعيين رمز الدخول", in: app)
        for digit in [2, 9, 4, 8, 1, 6] { app.buttons["keypad.digit.\(digit)"].tap() }
        expectHeading("تأكيد رمز الدخول", in: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.45)))
        XCTAssertTrue(create.waitForExistence(timeout: 5))

        app.buttons["onboarding.moreOptions"].tap()
        app.buttons["onboarding.importPrivateKey"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["اختر شبكة"].waitForExistence(timeout: 5))
        let aptos = app.descendants(matching: .any).matching(identifier: "import.choice.aptos").firstMatch
        XCTAssertTrue(aptos.exists)
        XCTAssertEqual(aptos.label, "Aptos")
        attach("Arabic chain picker", app)
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("Arbitrum")
        let evm = app.descendants(matching: .any).matching(identifier: "import.choice.evm").firstMatch
        XCTAssertTrue(evm.waitForExistence(timeout: 5))
        evm.tap()
        XCTAssertFalse(evm.isSelected, "Import actions must not become radio selections")
        XCTAssertEqual(app.buttons.matching(identifier: "import.popular.evm").count, 0,
                       "Search must show only the canonical result, not duplicate shortcuts")
        // Return without sending or saving a private key.
        app.terminate()
        app.launch()
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        XCTAssertEqual(create.label, "إنشاء محفظة جديدة", "Language persists across a cold launch")

        chooseLanguage("English", in: app)
        XCTAssertTrue(app.navigationBars.staticTexts["More Options"].exists)
        XCTAssertGreaterThan(app.buttons["options.close"].frame.midX, app.frame.midX,
                             "English restores the native trailing Close control")
        app.buttons["Close"].firstMatch.tap()
        XCTAssertEqual(create.label, "Create a new wallet")
        create.tap()
        expectHeading("Set a Passcode", in: app)
        XCTAssertLessThan(app.navigationBars.buttons.firstMatch.frame.midX, app.frame.midX)
        attach("English restored", app)
    }

    @MainActor private func chooseLanguage(_ name: String, in app: XCUIApplication) {
        app.buttons["onboarding.moreOptions"].tap()
        let picker = app.descendants(matching: .any).matching(identifier: "settings.language").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        let search = app.searchFields["settings.languageSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(name == "العربية" ? "Arabic" : "English")
        let choice = app.cells["language.choice.\(name == "العربية" ? "ar" : "en")"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
    }

    @MainActor private func expectHeading(_ title: String, in app: XCUIApplication) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", title),
                                                    object: app.staticTexts["passcode.title"])
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 8), .completed)
    }

    @MainActor private func attach(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

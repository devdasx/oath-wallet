import XCTest
import UIKit

/// Uses a fresh Keychain namespace and public test phrases on one disposable
/// simulator. Never reveals or screenshots a randomly generated recovery phrase.
final class OathWalletHomeUITests: XCTestCase {
    /// Exercise the actual SwiftUI/Metal/UIScrollView composition: checking the
    /// shader alone cannot catch a compressed fade in the scrolling overlay.
    @MainActor func testHomeCrossfadeBetweenSummaryAndAssets() {
        continueAfterFailure = false
        let device = XCUIDevice.shared
        let previousAppearance = device.appearance
        defer { device.appearance = previousAppearance }
        device.appearance = .light
        let app = configuredApp()
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["onboarding.importWallet"].waitForExistence(timeout: 15))
        app.buttons["onboarding.importWallet"].tap()
        let phrase = app.textViews["recovery.phrase"]
        XCTAssertTrue(phrase.waitForExistence(timeout: 8))
        phrase.typeText(String(repeating: "abandon ", count: 11) + "about")
        app.buttons["recovery.keyboardDone"].tap()
        app.buttons["recovery.import"].tap()
        finishSetup(app)

        let receive = app.buttons["home.receive"]
        let assets = app.staticTexts["Assets"].firstMatch
        XCTAssertTrue(assets.waitForExistence(timeout: 8))
        XCTAssertTrue(receive.isHittable)
        XCTAssertTrue(app.buttons["home.send"].isHittable)
        let image = XCUIScreen.main.screenshot().image.cgImage!
        let scale = CGFloat(image.width) / app.frame.width
        let from = ceil(receive.frame.maxY + 8)
        let to = floor(assets.frame.minY - 20)
        XCTAssertGreaterThan(to - from, 60)
        let crop = image.cropping(to: CGRect(x: CGFloat(image.width) * 0.48, y: from * scale,
            width: CGFloat(image.width) * 0.04, height: (to - from) * scale))!
        // One average sample per point avoids compression/dithering noise. The
        // cobalt fixture should blend over a region, not jump through a band.
        let height = Int(to - from)
        var samples = [UInt8](repeating: 0, count: height * 4)
        samples.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: height,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .high
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: height))
        }
        let intermediateRows = stride(from: 0, to: samples.count, by: 4).filter {
            let darkest = min(samples[$0], samples[$0 + 1], samples[$0 + 2])
            return (90...220).contains(darkest)
        }.count
        XCTAssertGreaterThanOrEqual(intermediateRows, 55, "The fade must not collapse to a narrow colored/white stripe")
        print("OATH_HOME_FADE_INTERMEDIATE_POINTS=\(intermediateRows)")
        capture("home-crossfade-light", app)

        let resting = screenPixel(x: 0.5, y: (assets.frame.minY - 8) / app.frame.height)
        XCTAssertLessThanOrEqual(max(resting.r, resting.g, resting.b) - min(resting.r, resting.g, resting.b), 2)
        XCTAssertGreaterThan(resting.r, 235)

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["keyboard.keyboardDone"].exists,
                       "Native search must not attach the form keyboard accessory")
        capture("home-search-native-keyboard", app)
        app.buttons["close"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)

        // A short pull must move the same boundary with the actions and settle
        // without a gap; it does not need to trigger a wallet/network refresh.
        let originalTop = receive.frame.minY
        let scroll = app.scrollViews["home.scroll"]
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 45)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(receive.frame.minY - originalTop) < 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 8), .completed)
        capture("home-crossfade-after-pull", app)

        // Exercise the actual persisted appearance choice, including returning
        // from its full-screen presentation to the existing Home scroll host.
        app.buttons["home.settings"].tap()
        let appearance = app.buttons["settings.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        let darkOption = app.buttons["settings.appearance.dark"]
        XCTAssertTrue(darkOption.waitForExistence(timeout: 5))
        darkOption.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: darkOption)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        let close = app.buttons["options.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        let appearanceChanged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let pixel = self.screenPixel(x: 0.5, y: (assets.frame.minY - 8) / app.frame.height)
            return max(pixel.r, pixel.g, pixel.b) < 65
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [appearanceChanged], timeout: 8), .completed)
        XCTAssertTrue(receive.isHittable)
        let dark = screenPixel(x: 0.5, y: (assets.frame.minY - 8) / app.frame.height)
        XCTAssertLessThanOrEqual(max(dark.r, dark.g, dark.b) - min(dark.r, dark.g, dark.b), 2)
        capture("home-crossfade-dark", app)

        app.buttons["home.settings"].tap()
        app.buttons["settings.language"].tap()
        let languageSearch = app.searchFields["settings.languageSearch"]
        XCTAssertTrue(languageSearch.waitForExistence(timeout: 5))
        languageSearch.tap(); languageSearch.typeText("Arabic")
        XCTAssertFalse(app.buttons["keyboard.keyboardDone"].exists)
        app.cells["language.choice.ar"].tap()
        app.buttons["options.close"].tap()
        capture("home-crossfade-arabic", app)
        app.searchFields.firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["keyboard.keyboardDone"].exists)
        capture("home-search-native-keyboard-arabic", app)
    }

    @MainActor func testPullBlurReturnsToOriginalHome() {
        continueAfterFailure = false
        let app = configuredApp()
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["onboarding.importWallet"].waitForExistence(timeout: 15))
        app.buttons["onboarding.importWallet"].tap()
        let phrase = app.textViews["recovery.phrase"]
        XCTAssertTrue(phrase.waitForExistence(timeout: 8))
        phrase.typeText(String(repeating: "abandon ", count: 11) + "about")
        app.buttons["recovery.keyboardDone"].tap()
        app.buttons["recovery.import"].tap()
        finishSetup(app)

        let settings = app.buttons["home.settings"]
        let receive = app.buttons["home.receive"]
        let toolbarTop = settings.frame.minY
        let receiveTop = receive.frame.minY
        let scroll = app.scrollViews["home.scroll"]
        capture("pull-blur-before", app)
        for (name, distance, hold): (String, CGFloat, TimeInterval) in [
            ("short", 45, 1.0), ("refresh", 250, 3.0)
        ] {
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            let end = start.withOffset(CGVector(dx: 0, dy: distance))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: hold)
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                abs(receive.frame.minY - receiveTop) < 1
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 8), .completed)
            XCTAssertEqual(settings.frame.minY, toolbarTop, accuracy: 1)
            XCTAssertTrue(receive.isHittable)
            capture("pull-blur-after-\(name)", app)
        }
        scroll.swipeUp(velocity: .slow)
        XCTAssertEqual(settings.frame.minY, toolbarTop, accuracy: 1)
        capture("pull-blur-normal-scroll", app)
    }

    @MainActor func testTransparentToolbarFollowsContentAndAppearance() {
        continueAfterFailure = false
        let device = XCUIDevice.shared
        let previousAppearance = device.appearance
        defer { device.appearance = previousAppearance }
        device.appearance = .light

        let app = configuredApp()
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["onboarding.importWallet"].waitForExistence(timeout: 15))
        app.buttons["onboarding.importWallet"].tap()
        let phrase = app.textViews["recovery.phrase"]
        XCTAssertTrue(phrase.waitForExistence(timeout: 8))
        phrase.typeText(String(repeating: "abandon ", count: 11) + "about")
        app.buttons["recovery.keyboardDone"].tap()
        app.buttons["recovery.import"].tap()
        finishSetup(app)

        let settings = app.buttons["home.settings"]
        let toolbarTop = settings.frame.minY
        let sampleY = settings.frame.midY / app.frame.height
        let scroll = app.scrollViews["home.scroll"]
        let edge = screenPixel(x: 0.70, y: sampleY)
        XCTAssertGreaterThan(edge.b - edge.r, 25, "At the top, artwork remains visible behind the toolbar")
        capture("toolbar-transparent-at-top", app)

        scroll.swipeUp(velocity: .slow)
        XCTAssertEqual(settings.frame.minY, toolbarTop, accuracy: 1)
        XCTAssertEqual(app.navigationBars.count, 1, "Home uses one native navigation bar")
        let scrolled = screenPixel(x: 0.70, y: sampleY)
        XCTAssertGreaterThan(scrolled.r + scrolled.g + scrolled.b, edge.r + edge.g + edge.b,
                             "The lighter asset content scrolls beneath the transparent toolbar")
        capture("toolbar-transparent-over-assets", app)

        // The content beneath the clear toolbar follows the app's appearance.
        settings.tap()
        let appearance = app.buttons["settings.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        app.buttons["Dark"].tap()
        app.buttons["options.close"].tap()
        let dark = screenPixel(x: 0.70, y: sampleY)
        XCTAssertLessThan(max(dark.r, dark.g, dark.b), 65)
        capture("toolbar-dark-choice-while-scrolled", app)
        settings.tap()
        appearance.tap()
        app.buttons["Light"].tap()
        app.buttons["options.close"].tap()

        for _ in 0..<4 {
            scroll.swipeDown(velocity: .slow)
            let pixel = screenPixel(x: 0.70, y: sampleY)
            if pixel.b - pixel.r > 25 { break }
        }
        XCTAssertTrue(app.buttons["home.receive"].isHittable)
        XCTAssertEqual(settings.frame.minY, toolbarTop, accuracy: 1)
        let restored = screenPixel(x: 0.70, y: sampleY)
        XCTAssertGreaterThan(restored.b - restored.r, 25,
                             "Returning to the top reveals the artwork beneath the transparent toolbar")
        capture("toolbar-restored-at-top", app)
    }

    @MainActor func testShortAndHeldRefreshMotion() {
        continueAfterFailure = false
        let app = configuredApp()
        app.launchArguments.removeAll { $0 == "-oath-artwork-reduce-motion" }
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.importWallet"].waitForExistence(timeout: 15))
        app.buttons["onboarding.importWallet"].tap()
        let field = app.textViews["recovery.phrase"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.typeText(String(repeating: "abandon ", count: 11) + "about")
        app.buttons["recovery.keyboardDone"].tap()
        app.buttons["recovery.import"].tap()
        finishSetup(app)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 15))
        let top = app.buttons["home.settings"].frame.minY
        let scroll = app.scrollViews["home.scroll"]
        capture("motion-begin", app)
        for (depth, hold) in [(0.24, 0.0), (0.42, 0.0), (0.72, 2.0), (0.64, 0.0)] {
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.16))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: depth))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: hold)
            XCTAssertTrue(app.buttons["home.receive"].isHittable)
            XCTAssertEqual(app.buttons["home.settings"].frame.minY, top, accuracy: 1)
        }
        capture("motion-end", app)
        // A shorter body after native bottom-search filtering must still size
        // itself, bounce, and keep its opaque lower surface behind the rows.
        let search = app.searchFields["Search assets"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(search.frame.midY, app.frame.height * 0.75)
        search.tap()
        search.typeText("Solana\n")
        XCTAssertTrue(app.buttons["home.network.solana"].isHittable)
        XCTAssertFalse(app.buttons["home.network.bitcoin"].exists)
        capture("motion-filtered", app)
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
        let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.6)
        XCTAssertTrue(app.buttons["home.network.solana"].isHittable)
        app.buttons["close"].tap()
        XCTAssertTrue(app.buttons["home.network.bitcoin"].waitForExistence(timeout: 5))
        scroll.swipeUp()
        XCTAssertEqual(app.buttons["home.settings"].frame.minY, top, accuracy: 1)
        app.buttons["home.settings"].tap()
        XCTAssertTrue(app.buttons["options.close"].waitForExistence(timeout: 5))
        app.buttons["options.close"].tap()
    }

    @MainActor func testNativeHomeBarsAndAssetSearch() {
        continueAfterFailure = false
        let app = configuredApp()
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["onboarding.importWallet"].waitForExistence(timeout: 15))
        app.buttons["onboarding.importWallet"].tap()
        let field = app.textViews["recovery.phrase"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.typeText(String(repeating: "abandon ", count: 11) + "about")
        app.buttons["recovery.keyboardDone"].tap()
        app.buttons["recovery.import"].tap()
        finishSetup(app)

        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 8))
        XCTAssertTrue(tabs.buttons["Wallet"].isSelected)
        XCTAssertTrue(tabs.buttons["History"].exists)
        XCTAssertTrue(tabs.buttons["Search"].exists)
        XCTAssertFalse(app.searchFields.firstMatch.isHittable, "Wallet must not have a persistent search field")
        XCTAssertTrue(app.navigationBars.buttons["home.scanner"].isHittable)
        XCTAssertTrue(app.navigationBars.buttons["home.settings"].isHittable)

        tabs.buttons["Search"].tap()
        let assetSearch = app.searchFields.firstMatch
        XCTAssertTrue(assetSearch.waitForExistence(timeout: 5))
        assertBottomSearch(assetSearch, in: app)
        assetSearch.tap(); assetSearch.typeText("Solana")
        XCTAssertTrue(app.buttons["home.network.solana"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["home.network.bitcoin"].exists)
        XCTAssertFalse(app.buttons["keyboard.keyboardDone"].exists)
        app.buttons["home.network.solana"].tap()
        XCTAssertTrue(app.buttons["asset.information"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        XCTAssertFalse(app.searchFields.firstMatch.isHittable)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["home.receive"].waitForExistence(timeout: 5))
        XCTAssertTrue(tabs.buttons["Wallet"].isSelected)
        XCTAssertFalse(app.searchFields.firstMatch.isHittable, "Back returns to Home with search closed")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        tabs.buttons["Search"].tap()
        XCTAssertTrue(assetSearch.waitForExistence(timeout: 5))
        XCTAssertEqual(assetSearch.value as? String, assetSearch.placeholderValue)
        assertBottomSearch(assetSearch, in: app)
        closeSearch(in: app)
        tabs.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 8))
        tabs.buttons["Search"].tap()
        let historySearch = app.searchFields["Search transactions"]
        XCTAssertTrue(historySearch.waitForExistence(timeout: 5))
        assertBottomSearch(historySearch, in: app)
        historySearch.tap(); historySearch.typeText("no-matching-transaction-id")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.network.")).firstMatch.exists)
        XCTAssertFalse(app.buttons["keyboard.keyboardDone"].exists)
        closeSearch(in: app)
        tabs.buttons["Wallet"].tap()
        XCTAssertTrue(app.buttons["home.receive"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.searchFields.firstMatch.isHittable)
        tabs.buttons["Search"].tap()
        XCTAssertTrue(app.searchFields["Search assets or contract address"].waitForExistence(timeout: 5))
        assertBottomSearch(app.searchFields.firstMatch, in: app)
    }

    @MainActor private func assertBottomSearch(_ field: XCUIElement, in app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        let bottom = keyboard.exists ? keyboard.frame.minY : app.frame.maxY
        XCTAssertGreaterThan(field.frame.midY, app.frame.height * 0.4,
                             "Native tab search must not fall back to the top navigation drawer")
        XCTAssertLessThan(bottom - field.frame.maxY, 160)
    }

    @MainActor private func closeSearch(in app: XCUIApplication) {
        let close = app.buttons["Close"]
        if close.isHittable { close.tap() }
        else if app.buttons["Cancel"].isHittable { app.buttons["Cancel"].tap() }
    }

    /// Keep the real renderer running: a still screenshot after release cannot
    /// detect a one-frame safe-area gap during UIKit's refresh inset changes.
    /// The recording checks BOTH the status bar and the card/button boundary at
    /// every frame, including release. Checking the top alone missed clipping.
    @MainActor func testLiveHeaderRemainsCoveredAcrossRepeatedRefreshes() {
        continueAfterFailure = false
        let app = configuredApp()
        app.launchArguments.removeAll { $0 == "-oath-artwork-reduce-motion" }
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.importWallet"].waitForExistence(timeout: 15))
        app.buttons["onboarding.importWallet"].tap()
        let field = app.textViews["recovery.phrase"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.typeText(String(repeating: "abandon ", count: 11) + "about")
        app.buttons["recovery.keyboardDone"].tap()
        app.buttons["recovery.import"].tap()
        finishSetup(app)
        let settings = app.buttons["home.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        let toolbarTop = settings.frame.minY
        XCTAssertEqual(app.navigationBars.count, 1)
        capture("refresh-live-begin", app)

        let scroll = app.scrollViews["home.scroll"]
        for (index, depth) in [0.34, 0.64, 0.42, 0.70, 0.55, 0.64].enumerated() {
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.16))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: depth))
            start.press(forDuration: 0.05, thenDragTo: end,
                        withVelocity: index.isMultiple(of: 2) ? .fast : .slow,
                        thenHoldForDuration: index.isMultiple(of: 2) ? 0 : 0.4)
            XCTAssertTrue(app.buttons["home.receive"].isHittable)
            XCTAssertEqual(settings.frame.minY, toolbarTop, accuracy: 1)
        }
        capture("refresh-live-end", app)
        // The stationary full-screen artwork must not leak below a short body.
        let search = app.searchFields["Search assets"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Solana\n")
        XCTAssertTrue(app.buttons["home.network.solana"].isHittable)
        XCTAssertFalse(app.buttons["home.network.bitcoin"].exists)
        capture("refresh-short-content", app)
        app.buttons["close"].tap()
        scroll.swipeUp()
        XCTAssertEqual(settings.frame.minY, toolbarTop, accuracy: 1)
        XCTAssertTrue(settings.isHittable)
        capture("refresh-live-scrolled", app)
        app.terminate()
    }

    @MainActor func testContinuousHeaderPullToRefreshAndPinnedToolbar() {
        continueAfterFailure = false
        let app = configuredApp()
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.importWallet"].waitForExistence(timeout: 15))
        app.buttons["onboarding.importWallet"].tap()
        let field = app.textViews["recovery.phrase"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.typeText(String(repeating: "abandon ", count: 11) + "about")
        app.buttons["recovery.keyboardDone"].tap()
        app.buttons["recovery.import"].tap()
        finishSetup(app)
        let settings = app.buttons["home.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        XCTAssertEqual(app.navigationBars.count, 1)
        XCTAssertFalse(app.staticTexts["Self-custodial wallet"].exists)
        XCTAssertFalse(app.staticTexts["26 networks"].exists)
        // The balance amount retains a truthful accessibility description, but
        // there is no visible balance-unavailable caption or action anymore.
        XCTAssertFalse(app.buttons["Balance unavailable"].exists)
        let toolbarTop = settings.frame.minY
        XCTAssertTrue(settings.isHittable)
        capture("home-continuous-header", app)

        let scroll = app.scrollViews["home.scroll"]
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.16))
        let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 3)
        XCTAssertTrue(app.buttons["home.receive"].isHittable)
        XCTAssertEqual(settings.frame.minY, toolbarTop, accuracy: 1)
        capture("home-after-refresh", app)

        scroll.swipeUp()
        XCTAssertEqual(settings.frame.minY, toolbarTop, accuracy: 1)
        XCTAssertTrue(settings.isHittable)
        capture("home-pinned-toolbar", app)
        settings.tap()
        XCTAssertTrue(app.buttons["options.close"].waitForExistence(timeout: 5))
        app.buttons["options.close"].tap()
        app.terminate()
    }

    @MainActor func testCreatePersistUnlockAndReceive() {
        continueAfterFailure = false
        let app = configuredApp()
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.createWallet"].waitForExistence(timeout: 15))
        app.buttons["onboarding.createWallet"].tap()
        finishSetup(app)
        XCTAssertTrue(app.buttons["home.receive"].waitForExistence(timeout: 15))
        capture("home-created", app)
        app.buttons["home.network.bitcoin"].tap()
        let address = app.staticTexts["receive.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 8))
        let before = address.label
        XCTAssertTrue(before.hasPrefix("bc1q"))
        XCTAssertTrue(app.images["receive.qr"].exists)
        capture("receive-bitcoin", app)
        app.buttons["options.close"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["wallet.unlock.title"].waitForExistence(timeout: 15))
        enterPIN(app, digits: [0, 0, 0, 0, 0, 0])
        XCTAssertTrue(app.staticTexts["Incorrect passcode. Try again."].waitForExistence(timeout: 8))
        enterPIN(app)
        XCTAssertTrue(app.buttons["home.receive"].waitForExistence(timeout: 15))
        app.buttons["home.network.bitcoin"].tap()
        XCTAssertTrue(address.waitForExistence(timeout: 8))
        XCTAssertEqual(address.label, before)
        app.buttons["options.close"].tap()
        app.terminate()
    }

    @MainActor func testImportLeadsToKnownAddressesAndArabicHome() {
        continueAfterFailure = false
        let app = configuredApp()
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.importWallet"].waitForExistence(timeout: 15))
        app.buttons["onboarding.importWallet"].tap()
        let field = app.textViews["recovery.phrase"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.typeText(String(repeating: "abandon ", count: 11) + "about")
        app.buttons["recovery.keyboardDone"].tap()
        let submit = app.buttons["recovery.import"]
        for _ in 0..<3 where !submit.isHittable { app.swipeUp() }
        submit.tap()
        finishSetup(app)
        XCTAssertTrue(app.buttons["home.receive"].waitForExistence(timeout: 15))
        app.buttons["home.network.ethereum"].tap()
        let address = app.staticTexts["receive.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 8))
        XCTAssertEqual(address.label, "0x9858EfFD232B4033E47d90003D41EC34EcaEda94")
        capture("receive-ethereum-fixture", app)
        app.buttons["options.close"].tap()
        capture("home-imported", app)
        let search = app.searchFields["Search assets"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Solana\n")
        let solana = app.buttons["home.network.solana"]
        for _ in 0..<3 where !solana.isHittable { app.swipeUp() }
        XCTAssertTrue(solana.isHittable)
        XCTAssertFalse(app.buttons["home.network.bitcoin"].exists)
        solana.tap()
        XCTAssertTrue(address.waitForExistence(timeout: 8))
        XCTAssertFalse(address.label.hasPrefix("0x"))
        app.buttons["options.close"].tap()
        app.terminate()

        // Same wallet, only change native locale/layout and Dynamic Type.
        app.launchArguments += ["-oath.languagePreference", "ar",
                                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["keypad.digit.2"].waitForExistence(timeout: 15))
        enterPIN(app)
        let receive = app.buttons["home.receive"]
        XCTAssertTrue(receive.waitForExistence(timeout: 15))
        for _ in 0..<4 where !receive.isHittable { app.swipeUp() }
        XCTAssertTrue(receive.isHittable)
        XCTAssertTrue(app.staticTexts["الرصيد الإجمالي"].exists)
        capture("home-arabic-accessibility", app)
        receive.tap()
        let bitcoin = app.buttons["receive.network.bitcoin"]
        // The content-sized sheet remains scrollable at the largest font size.
        for _ in 0..<8 where !bitcoin.isHittable { app.swipeUp() }
        XCTAssertTrue(bitcoin.isHittable)
        XCTAssertTrue(app.buttons["options.close"].isHittable)
        capture("receive-picker-arabic-accessibility", app)
        bitcoin.tap()
        XCTAssertTrue(app.staticTexts["receive.address"].waitForExistence(timeout: 8))
        capture("receive-bitcoin-arabic-accessibility", app)
        let copy = app.buttons["receive.copy"]
        for _ in 0..<5 where !copy.isHittable { app.scrollViews["options.scrollContent"].swipeUp() }
        XCTAssertTrue(copy.isHittable)
        app.terminate()
    }

    @MainActor func testRecoveryDisclosureRequiresAcknowledgementAndPasscode() {
        continueAfterFailure = false
        let app = configuredApp()
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.importWallet"].waitForExistence(timeout: 15))
        app.buttons["onboarding.importWallet"].tap()
        let field = app.textViews["recovery.phrase"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.typeText(String(repeating: "abandon ", count: 11) + "about")
        app.buttons["recovery.keyboardDone"].tap()
        app.buttons["recovery.import"].tap()
        finishSetup(app)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 15))
        app.buttons["home.settings"].tap()
        XCTAssertTrue(app.buttons["settings.wallets"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings.backup"].exists)
        app.buttons["settings.wallets"].tap()
        let wallet = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.wallet.")).firstMatch
        XCTAssertTrue(wallet.waitForExistence(timeout: 5))
        wallet.tap()
        let recovery = app.buttons["walletSettings.recovery"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 5))
        if !recovery.isHittable { app.swipeUp() }
        recovery.tap()
        let understand = app.buttons["recoveryDisclosure.understand"]
        XCTAssertTrue(understand.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["recoveryDisclosure.copy"].exists)
        let close = app.buttons["options.close"]
        let initialTop = close.frame.minY
        understand.tap()
        // This test's isolated fixture has no biometric enrollment.
        XCTAssertTrue(app.buttons["keypad.digit.1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["recoveryDisclosure.copy"].exists)
        enterPIN(app, digits: [0, 0, 0, 0, 0, 0])
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.firstMatch.buttons.firstMatch.tap()
        XCTAssertFalse(app.buttons["recoveryDisclosure.copy"].exists)
        enterPIN(app)
        let copy = app.buttons["recoveryDisclosure.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 8))
        XCTAssertTrue(app.otherElements["recoveryDisclosure.word.1"].exists
                      || app.staticTexts["recoveryDisclosure.word.1"].exists)
        XCTAssertTrue(app.otherElements["recoveryDisclosure.word.12"].exists
                      || app.staticTexts["recoveryDisclosure.word.12"].exists)
        XCTAssertTrue(app.staticTexts["Never share or lose your recovery phrase."].exists)
        XCTAssertEqual(close.frame.minY, initialTop, accuracy: 1,
                       "The full-screen Settings navigation stays pinned when recovery words appear")
        XCTAssertTrue(copy.isHittable)
        copy.tap()
        XCTAssertTrue(app.buttons["recoveryDisclosure.copy"].staticTexts["Copied"].exists)
        app.navigationBars.buttons.matching(NSPredicate(format: "identifier != %@", "options.close")).firstMatch.tap()
        XCTAssertTrue(app.buttons["keypad.digit.1"].waitForExistence(timeout: 5))
        XCTAssertFalse(copy.exists, "Going back must require authentication again")
        close.tap()
        XCTAssertTrue(app.buttons["home.receive"].isHittable)
        app.terminate()
    }

    @MainActor func testTransactionNativeChromeAndSharing() {
        continueAfterFailure = false
        let app = configuredApp()
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.importWallet"].waitForExistence(timeout: 15))
        app.buttons["onboarding.importWallet"].tap()
        let field = app.textViews["recovery.phrase"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        // Published BIP39 vector; never a user's wallet.
        field.typeText(String(repeating: "abandon ", count: 11) + "about")
        app.buttons["recovery.keyboardDone"].tap()
        app.buttons["recovery.import"].tap()
        finishSetup(app)
        app.buttons["home.settings"].tap()
        app.buttons["settings.language"].tap()
        let languageSearch = app.searchFields["settings.languageSearch"]
        XCTAssertTrue(languageSearch.waitForExistence(timeout: 5))
        languageSearch.tap(); languageSearch.typeText("Arabic")
        app.cells["language.choice.ar"].tap()
        app.buttons["options.close"].tap()
        let bitcoin = app.buttons["home.network.bitcoin"]
        XCTAssertTrue(bitcoin.waitForExistence(timeout: 10))
        for _ in 0..<3 where !bitcoin.isHittable { app.scrollViews["home.scroll"].swipeUp() }
        bitcoin.tap()
        XCTAssertTrue(app.buttons["asset.information"].waitForExistence(timeout: 8))
        let transaction = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'asset.transaction.' AND label CONTAINS %@", "تم الاستلام")).firstMatch
        app.scrollViews["asset.scroll"].swipeUp()
        XCTAssertTrue(transaction.waitForExistence(timeout: 90), "Public Bitcoin activity is needed for this navigation check")
        for _ in 0..<4 where !transaction.isHittable { app.scrollViews["asset.scroll"].swipeUp() }
        transaction.tap()
        let export = app.buttons["transaction.share"]
        XCTAssertTrue(export.waitForExistence(timeout: 8))
        XCTAssertTrue(app.otherElements["transaction.assetLogo"].exists)
        XCTAssertEqual(app.navigationBars.count, 1)
        XCTAssertTrue(app.navigationBars.buttons["transaction.share"].exists)
        XCTAssertFalse(app.staticTexts["القيمة التقديرية بالسعر الحالي"].exists)
        let copy = app.buttons["transaction.copy.asset.transaction_id"]
        XCTAssertTrue(copy.waitForExistence(timeout: 8))
        for _ in 0..<2 where !copy.isHittable { app.scrollViews.firstMatch.swipeUp() }
        copy.tap()
        XCTAssertEqual(copy.frame.width, 44, accuracy: 1)
        XCTAssertFalse(app.buttons["transaction.explorer"].exists, "Explorer belongs in the menu, not the receipt")
        capture("transaction-arabic-native-chrome", app)
        export.tap()
        XCTAssertTrue(app.buttons["transaction.explorer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["transaction.shareLink"].exists)
        app.buttons["transaction.shareImage"].tap()
        XCTAssertTrue(app.cells["Copy"].waitForExistence(timeout: 10), app.debugDescription)
        capture("transaction-native-image-share", app)
        app.buttons["header.closeButton"].tap()
        XCTAssertTrue(export.isHittable)
        export.tap()
        app.buttons["transaction.shareLink"].tap()
        XCTAssertTrue(app.cells["Copy"].waitForExistence(timeout: 10), app.debugDescription)
        capture("transaction-native-link-share", app)
        app.buttons["header.closeButton"].tap()
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["asset.information"].waitForExistence(timeout: 8))
        for _ in 0..<3 { app.scrollViews["asset.scroll"].swipeDown() }
        capture("transaction-return-to-artwork", app)
        app.terminate()
    }

    @MainActor private func configuredApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-oath.languagePreference", "en", "-oath.walletTestScope", UUID().uuidString,
                               "-oath-artwork-reduce-motion"]
        return app
    }

    @MainActor private func finishSetup(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["passcode.title"].waitForExistence(timeout: 8))
        enterPIN(app)
        let confirmation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Confirm Passcode"),
                                                     object: app.staticTexts["passcode.title"])
        XCTAssertEqual(XCTWaiter.wait(for: [confirmation], timeout: 8), .completed)
        enterPIN(app)
        // No biometrics are enrolled in this disposable simulator for these
        // tests. The production flow still automatically checks availability.
        app.completeWalletCustomization()
        XCTAssertTrue(app.buttons["home.receive"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.alerts["Passcode set"].exists)
    }

    @MainActor private func enterPIN(_ app: XCUIApplication, digits: [Int] = [2, 9, 4, 8, 1, 6]) {
        for digit in digits { app.buttons["keypad.digit.\(digit)"].tap() }
    }

    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func screenPixel(x: CGFloat, y: CGFloat) -> (r: Int, g: Int, b: Int) {
        let image = XCUIScreen.main.screenshot().image.cgImage!
        let point = CGRect(x: CGFloat(image.width) * x, y: CGFloat(image.height) * y, width: 1, height: 1)
        let pixel = image.cropping(to: point)!
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (Int(rgba[0]), Int(rgba[1]), Int(rgba[2]))
    }
}

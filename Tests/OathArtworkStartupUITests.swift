import XCTest
import UIKit

/// One device, only welcome startup. No wallet secrets, camera, or Keychain use.
final class OathArtworkStartupUITests: XCTestCase {
    @MainActor
    func testArtworkPrecedesDelayedRendererAndSurvivesReturn() {
        continueAfterFailure = false
        let app = launch(arguments: ["-oath-artwork-delay", "15"])
        let artwork = app.otherElements["onboarding.artwork"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 5))
        XCTAssertEqual(artwork.value as? String, "bundled")
        XCTAssertTrue(app.buttons["onboarding.createWallet"].isHittable)
        assertArtwork(XCUIScreen.main.screenshot(), name: "startup-bundled")
        XCTAssertTrue(waitForRenderer(artwork), "Metal must finish rendering; pixel checks below verify its visible output")
        let first = XCUIScreen.main.screenshot()
        assertArtwork(first, name: "startup-live")
        Thread.sleep(forTimeInterval: 1.5)
        let next = XCUIScreen.main.screenshot()
        let before = pixels(first.image), after = pixels(next.image)
        // Only sample the silk at the side of the screen, away from logo,
        // clock, feature capsule, or any other UI animation.
        var changes = 0
        for y in stride(from: 100, to: 500, by: 3) {
            for x in 5..<30 {
                let offset = (y * 300 + x) * 4
                if abs(Int(before[offset + 2]) - Int(after[offset + 2])) > 3 { changes += 1 }
            }
        }
        XCTAssertGreaterThan(changes, 100, "The live silk must actually animate")
        app.buttons["onboarding.importWallet"].tap()
        XCTAssertTrue(app.textViews["recovery.phrase"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(artwork.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForRenderer(artwork, timeout: 5), "Returning should reuse the prepared resources")
        assertArtwork(XCUIScreen.main.screenshot(), name: "startup-return")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(waitForRenderer(artwork, timeout: 5))
        assertArtwork(XCUIScreen.main.screenshot(), name: "startup-foreground")
        app.terminate()
    }

    @MainActor
    func testArtworkRemainsVisibleWhenRendererUnavailable() {
        continueAfterFailure = false
        let app = launch(arguments: ["-oath-artwork-unavailable"])
        let artwork = app.otherElements["onboarding.artwork"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 5))
        XCTAssertEqual(artwork.value as? String, "bundled")
        assertArtwork(XCUIScreen.main.screenshot(), name: "startup-unavailable")
        // Preparation failure must not block any welcome action.
        app.buttons["onboarding.moreOptions"].tap()
        XCTAssertTrue(app.buttons["onboarding.restoreICloud"].waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    func testReducedMotionStillPresentsFirstFrame() {
        continueAfterFailure = false
        let app = launch(arguments: ["-oath-artwork-reduce-motion"])
        let artwork = app.otherElements["onboarding.artwork"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForRenderer(artwork, timeout: 10), "A paused animation still owes the view a first frame")
        assertArtwork(XCUIScreen.main.screenshot(), name: "startup-reduced-motion")
        app.terminate()
    }

    @MainActor
    private func launch(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-oath.languagePreference", "en", "-oath-artwork-diagnostics"] + arguments
        app.launch()
        return app
    }

    @MainActor
    private func waitForRenderer(_ artwork: XCUIElement, timeout: TimeInterval = 25) -> Bool {
        let predicate = NSPredicate(format: "value == %@", "rendered")
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: artwork)], timeout: timeout) == .completed
    }

    @MainActor
    private func assertArtwork(_ screenshot: XCUIScreenshot, name: String) {
        let bytes = pixels(screenshot.image)
        var blue = 0, whiteLogo = 0
        for y in 70..<340 {
            for x in 12..<288 {
                let p = (y * 300 + x) * 4
                let r = Int(bytes[p]), g = Int(bytes[p + 1]), b = Int(bytes[p + 2])
                if b > r + 20 && b > 35 { blue += 1 }
                if y < 210 && x > 50 && x < 250 && r > 185 && g > 185 && b > 185 { whiteLogo += 1 }
            }
        }
        XCTAssertGreaterThan(blue, 15000, "Welcome must contain blue artwork before Metal is ready")
        XCTAssertGreaterThan(whiteLogo, 2000, "The opaque white logo must also be present")
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func pixels(_ image: UIImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 300 * 650 * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 300, height: 650, bitsPerComponent: 8,
                                    bytesPerRow: 300 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image.cgImage!, in: CGRect(x: 0, y: 0, width: 300, height: 650))
        }
        return bytes
    }
}

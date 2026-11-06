import XCTest
import SwiftUI
import OathNativeRefresh

/// Render the real hosted ring, with an app direction independent of the
/// device language. Labels alone cannot detect a backward completion symbol.
@MainActor final class DirectionTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testRingCheckmarkFollowsAppDirectionOnHomeAndAsset() async throws {
        for screen in ["home", "asset"] {
            for direction in [LayoutDirection.rightToLeft, .leftToRight] {
                try await checkResult(screen: screen, direction: direction)
            }
        }
    }

    private func checkResult(screen: String, direction: LayoutDirection) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let identifier = "direction.\(screen)"
        let rtl = direction == .rightToLeft
        var started = false
        let host = UIHostingController(rootView:
            NativeRefreshScroll(identifier: identifier, tint: .white,
                indicator: .progressRing, timing: .brief,
                action: {
                    started = true
                    // Match Home/Asset's timed acknowledgement while data work
                    // is pending. Removing this fixture cancels the local task.
                    try await Task.sleep(for: .seconds(30))
                }, onFailure: { XCTFail("Synthetic refresh must not fail") }, onScroll: { _ in }) {
                    Color.black.frame(height: 1600)
                }
                .environment(\.layoutDirection, direction)
                .environment(\.locale, Locale(identifier: rtl ? "ar" : "en"))
                .environment(\.scenePhase, .active))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await waitUntil("Native refresh attaches") {
            (self.find(host.view, identifier: identifier) as? UIScrollView)?.refreshControl != nil
        }
        let scroll = try XCTUnwrap(find(host.view, identifier: identifier) as? UIScrollView)
        let action = try XCTUnwrap(scroll.accessibilityCustomActions?.first)
        XCTAssertTrue(UIApplication.shared.sendAction(action.selector, to: action.target, from: scroll, for: nil))
        try await waitUntil("Timed check appears") {
            self.find(host.view, identifier: "refresh.ring.success") != nil
        }
        XCTAssertTrue(started)
        // Capture after the 0.5-second replacement, inside the 0.8-second hold.
        try await Task.sleep(for: .milliseconds(600))
        let indicator = try XCTUnwrap(find(host.view, identifier: identifier + ".brand"))
        XCTAssertTrue(scroll.refreshControl?.isRefreshing == true)
        XCTAssertGreaterThan(indicator.alpha, 0.9)
        indicator.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: indicator.bounds, format: format).image { context in
            UIColor.black.setFill()
            context.fill(indicator.bounds)
            XCTAssertTrue(indicator.drawHierarchy(in: indicator.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "\(screen)-refresh-check-\(rtl ? "RTL" : "LTR")"
        attachment.lifetime = .keepAlways
        add(attachment)
        let upperArm = try upperArmPosition(try XCTUnwrap(image.cgImage))
        if rtl {
            XCTAssertLessThan(upperArm, 0.42, "RTL check's long arm must point left on \(screen)")
        } else {
            XCTAssertGreaterThan(upperArm, 0.58, "LTR check's long arm must point right on \(screen)")
        }
    }

    /// Independently measure the check's handedness from its rendered white
    /// pixels; don't assert a view property or duplicate the production modifier.
    private func upperArmPosition(_ image: CGImage) throws -> Double {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(rendered)
        var points: [(x: Int, y: Int)] = []
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if pixels[offset] > 200 && pixels[offset + 1] > 200 && pixels[offset + 2] > 200 {
                    points.append((x, y))
                }
            }
        }
        XCTAssertGreaterThan(points.count, 50, "The snapshot must contain a visible check")
        let minX = try XCTUnwrap(points.map(\.x).min()), maxX = try XCTUnwrap(points.map(\.x).max())
        let minY = try XCTUnwrap(points.map(\.y).min()), maxY = try XCTUnwrap(points.map(\.y).max())
        let upper = points.filter { $0.y < minY + (maxY - minY) / 3 }
        XCTAssertFalse(upper.isEmpty)
        return upper.reduce(0.0) { $0 + Double($1.x - minX) / Double(maxX - minX) } / Double(upper.count)
    }

    private func find(_ view: UIView, identifier: String) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        for child in view.subviews {
            if let result = find(child, identifier: identifier) { return result }
        }
        return nil
    }

    private func waitUntil(_ message: String, _ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message)
        throw NSError(domain: "RefreshDirectionFixture", code: 1)
    }
}

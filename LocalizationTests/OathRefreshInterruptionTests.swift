import XCTest
import SwiftUI
import OathNativeRefresh
@testable import OathAtmosphere

/// Exercises the real UIKit control and production refresh owner without a
/// wallet, network request, or production-only test hook.
@MainActor final class OathRefreshInterruptionTests: XCTestCase {
    private enum FixtureError: Error { case failed }

    func testNativeReactivationDuringResultReturnCannotLatchControl() async throws {
        for fails in [false, true] {
            try await checkInterruptedReturn(fails: fails)
        }
    }

    /// The old list-owned background paints its upward overlap on the later
    /// sibling plane. A black foreground probe exposes that otherwise subtle
    /// veil; the shared layout must leave it untouched while fading underneath.
    func testPanelStaysBehindHeaderForeground() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        let header = VStack(spacing: 0) {
            Color.clear.frame(height: 240)
            HStack(spacing: 12) {
                Color.black.frame(height: 56).clipShape(.capsule)
                OathActionButton(title: "Send", icon: "arrow.up.right", appearance: .secondary, foreground: .white) { }
            }.padding(.horizontal, 24)
            Color.clear.frame(height: 8)
        }
        let root = OathHeaderScrollContent(viewportHeight: 800) { header } content: {
            Color.clear.frame(height: 450)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0.03, green: 0.3, blue: 0.4))
        .environment(\.colorScheme, .light)
        .ignoresSafeArea()
        let host = UIHostingController(rootView: root)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(600))
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "shared-fade-native-glass-and-foreground"
        attachment.lifetime = .keepAlways
        add(attachment)
        let cg = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        let scale = CGFloat(cg.width) / host.view.bounds.width
        func rgb(_ x: CGFloat, _ y: CGFloat) -> [Int] {
            let i = (Int(y * scale) * cg.width + Int(x * scale)) * 4
            return pixels[i..<i+3].map(Int.init)
        }
        // The header is 304 points high; its fade starts at 272. This probe
        // spans that exact boundary and stays inside the capsule's opaque core.
        for y: CGFloat in [266, 270, 274, 280, 287] {
            XCTAssertLessThanOrEqual(rgb(70, y).max()!, 1, "Fade must never recolor foreground controls")
        }
        // The current rounded panel starts below the header, without the old
        // overlapping gradient. Its lower canvas must remain uniformly opaque.
        XCTAssertTrue(zip(rgb(4, 480), rgb(4, 500)).allSatisfy { abs($0 - $1) <= 2 })
    }

    private func checkInterruptedReturn(fails: Bool) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        var requests = 0
        var failures = 0
        let host = UIHostingController(rootView:
            NativeRefreshScroll(identifier: "refresh.interruption", tint: .white, indicator: .oathLogo,
                action: {
                    requests += 1
                    if fails { throw FixtureError.failed }
                }, onFailure: { failures += 1 }, onScroll: { _ in }) {
                    Color.gray.frame(height: 1800)
                }
                .environment(\.scenePhase, .active))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await waitUntil("Refresh scroll attaches") { Self.scroll(in: host.view)?.window != nil }
        let scroll = try XCTUnwrap(Self.scroll(in: host.view))
        let control = try XCTUnwrap(scroll.refreshControl)

        // Hold the same nonzero offset as a finger interrupting collapse. This
        // makes the native callback order deterministic without private touch
        // injection or exposing internal state in the component's public API.
        scroll.contentInset.top = 60
        scroll.setContentOffset(CGPoint(x: 0, y: -60), animated: false)
        try activateRefresh(scroll)
        XCTAssertTrue(control.isRefreshing)
        try await waitUntil("First refresh completes") { requests == 1 && !control.isRefreshing }
        XCTAssertEqual(failures, fails ? 1 : 0)
        XCTAssertLessThan(scroll.contentOffset.y, -0.5, "The interrupted result is still returning")

        // A second native threshold event after the task ends must not leave
        // an ownerless UIRefreshControl pinning the result at a nonzero offset.
        control.beginRefreshing()
        control.sendActions(for: .valueChanged)
        XCTAssertFalse(control.isRefreshing, "The returning result must not keep an ownerless native refresh alive")
        XCTAssertEqual(requests, 1, "A completion gesture must not duplicate wallet work")

        scroll.contentInset = .zero
        scroll.setContentOffset(.zero, animated: false)
        try activateRefresh(scroll)
        XCTAssertTrue(control.isRefreshing, "After returning to rest, the next deliberate refresh is accepted")
        // UIKit may send its own threshold event after VoiceOver already began.
        control.sendActions(for: .valueChanged)
        XCTAssertTrue(control.isRefreshing, "A native event must preserve an owned request")
        try await waitUntil("The next refresh completes normally") { requests == 2 && !control.isRefreshing }
        XCTAssertEqual(failures, fails ? 2 : 0)
    }

    private func activateRefresh(_ scroll: UIScrollView) throws {
        let action = try XCTUnwrap(scroll.accessibilityCustomActions?.first)
        XCTAssertTrue(UIApplication.shared.sendAction(action.selector, to: action.target, from: scroll, for: nil))
    }

    private static func scroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.accessibilityIdentifier == "refresh.interruption" { return scroll }
        return view.subviews.lazy.compactMap { scroll(in: $0) }.first
    }

    private func waitUntil(_ message: String, _ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message)
        throw NSError(domain: "OathRefreshInterruptionTests", code: 1)
    }
}

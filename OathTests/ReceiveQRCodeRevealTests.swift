import CoreImage
import SwiftUI
import Testing
import UIKit
@testable import Aperture

/// Exercises the real UIKit/Core Animation primitive, without app screenshots,
/// live wallet material, network requests, or sending transactions.
@Suite(.serialized)
@MainActor
struct ReceiveQRCodeRevealTests {
    private static let address = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
    private static let bitcoin = "bitcoin:1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"

    @Test
    func waitsForBothAWindowAndLayout() async throws {
        let image = try await qr(Self.bitcoin)
        let view = ReceiveQRCodeRevealUIView()
        view.configure(image: image, payload: Self.bitcoin, animated: true)
        #expect(view.revealState == .waitingForDisplay)
        view.frame.size = CGSize(width: 300, height: 300)
        view.layoutIfNeeded()
        #expect(view.revealState == .waitingForDisplay)

        view.frame.size = .zero
        let host = try NativeListTestHost { Color.clear }
        defer { host.close() }
        host.rootView.addSubview(view)
        view.layoutIfNeeded()
        #expect(view.revealState == .waitingForDisplay)

        view.frame.size = CGSize(width: 300, height: 300)
        view.layoutIfNeeded()
        #expect(view.revealState == .revealing)
        try await waitForCompletion(view)
    }

    @Test
    func nativeAnimationHasAStaggeredSweepAndCleansItselfUp() async throws {
        let image = try await qr(Self.bitcoin)
        let host = try NativeListTestHost { Color.clear }
        defer { host.close() }
        let view = mount(image: image, payload: Self.bitcoin, in: host)
        let imageLayer = try #require(view.layer.sublayers?.first)
        let mask = try #require(imageLayer.mask)
        let tiles = try #require(mask.sublayers)
        #expect(tiles.count == 64)
        #expect(view.revealState == .revealing)
        let expectedFilter: CALayerContentsFilter = image.shouldInterpolate ? .linear : .nearest
        #expect(imageLayer.magnificationFilter == expectedFilter)
        #expect(imageLayer.minificationFilter == expectedFilter)
        #expect(CATransform3DIsIdentity(imageLayer.transform))
        #expect((imageLayer.contents as AnyObject?) === image)

        var starts: [Double] = []
        for tile in tiles {
            let animation = try #require(tile.animation(
                forKey: ReceiveQRCodeRevealUIView.animationKey
            ) as? CAKeyframeAnimation)
            #expect(animation.keyPath == "opacity")
            #expect(animation.duration == ReceiveQRCodeRevealUIView.duration)
            #expect(animation.repeatCount == 0)
            #expect(animation.values as? [Int] == [0, 0, 1, 1])
            let times = try #require(animation.keyTimes)
            #expect(times.count == 4)
            #expect(times.map(\.doubleValue) == times.map(\.doubleValue).sorted())
            starts.append(times[1].doubleValue)
            #expect(CATransform3DIsIdentity(tile.transform))
        }
        #expect(try #require(starts.first) < #require(starts.last))
        #expect(Set(starts).count > 8)
        let coveredArea = tiles.reduce(CGFloat.zero) { $0 + $1.frame.width * $1.frame.height }
        #expect(abs(coveredArea - view.bounds.width * view.bounds.height) < 0.001)

        // Wait for Core Animation's real completion delegate, not a manual
        // finish call or a mocked scheduler.
        try await waitForCompletion(view)
        #expect(imageLayer.mask == nil)
        #expect(tiles.allSatisfy { $0.animationKeys()?.isEmpty ?? true })
        #expect((imageLayer.contents as AnyObject?) === image)
        #expect(try decodedPayload(image) == Self.bitcoin)
    }

    @Test
    func repeatedUpdatesDoNotReplayOrRestartTheSamePayload() async throws {
        let image = try await qr(Self.bitcoin)
        let host = try NativeListTestHost { Color.clear }
        defer { host.close() }
        let view = mount(image: image, payload: Self.bitcoin, in: host)
        let imageLayer = try #require(view.layer.sublayers?.first)
        let mask = try #require(imageLayer.mask)
        for _ in 0..<10 {
            view.configure(image: image, payload: Self.bitcoin, animated: true)
            view.setNeedsLayout()
            view.layoutIfNeeded()
            #expect(imageLayer.mask === mask)
        }
        try await waitForCompletion(view)
        view.configure(image: image, payload: Self.bitcoin, animated: true)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        #expect(view.revealState == .visible)
        #expect(imageLayer.mask == nil)
    }

    @Test
    func reducedMotionShowsTheFullCodeImmediately() async throws {
        let image = try await qr(Self.bitcoin)
        let host = try NativeListTestHost { Color.clear }
        defer { host.close() }
        let view = mount(image: image, payload: Self.bitcoin, animated: false, in: host)
        #expect(view.revealState == .visible)
        #expect(view.layer.sublayers?.first?.mask == nil)
        view.configure(image: image, payload: Self.bitcoin, animated: true)
        #expect(view.revealState == .visible)
        #expect(view.layer.sublayers?.first?.mask == nil)
    }

    @Test
    func disablingMotionOrBackgroundingFinishesAnActiveReveal() async throws {
        let image = try await qr(Self.bitcoin)
        let host = try NativeListTestHost { Color.clear }
        defer { host.close() }
        let view = mount(image: image, payload: Self.bitcoin, in: host)
        #expect(view.revealState == .revealing)
        view.configure(image: image, payload: Self.bitcoin, animated: false)
        #expect(view.revealState == .visible)
        #expect(view.layer.sublayers?.first?.mask == nil)
        view.configure(image: image, payload: Self.bitcoin, animated: true)
        #expect(view.revealState == .visible)
    }

    @Test
    func newAddressNeverUsesTheOldImageOrItsCompletion() async throws {
        let firstImage = try await qr(Self.bitcoin)
        let nextPayload = "ethereum:\(Self.address)@1"
        let nextImage = try await qr(nextPayload)
        let host = try NativeListTestHost { Color.clear }
        defer { host.close() }
        let view = mount(image: firstImage, payload: Self.bitcoin, in: host)
        let imageLayer = try #require(view.layer.sublayers?.first)
        let oldAnimation = try #require(imageLayer.mask?.sublayers?.last?.animation(
            forKey: ReceiveQRCodeRevealUIView.animationKey
        ))
        let oldDelegate = try #require(oldAnimation.delegate)

        view.configure(image: nextImage, payload: nextPayload, animated: true)
        let newMask = try #require(imageLayer.mask)
        #expect((imageLayer.contents as AnyObject?) === nextImage)
        #expect(view.revealState == .revealing)
        // Simulate an already-enqueued completion arriving after the address changed.
        oldDelegate.animationDidStop?(oldAnimation, finished: true)
        await Task.yield()
        #expect(imageLayer.mask === newMask)
        #expect(view.revealState == .revealing)
        try await waitForCompletion(view)
        #expect(try decodedPayload(nextImage) == nextPayload)
    }

    @Test
    func rotationFinishesWithoutStretchingOrReplaying() async throws {
        let image = try await qr(Self.bitcoin)
        let host = try NativeListTestHost { Color.clear }
        defer { host.close() }
        let view = mount(image: image, payload: Self.bitcoin, in: host)
        view.frame.size = CGSize(width: 248, height: 248)
        view.layoutIfNeeded()
        #expect(view.revealState == .visible)
        #expect(view.layer.sublayers?.first?.mask == nil)
        #expect(view.layer.sublayers?.first?.frame == view.bounds)
        view.configure(image: image, payload: Self.bitcoin, animated: true)
        #expect(view.revealState == .visible)
    }

    @Test
    func detachingCancelsAndReattachingDoesNotReplay() async throws {
        let image = try await qr(Self.bitcoin)
        let host = try NativeListTestHost { Color.clear }
        defer { host.close() }
        let view = mount(image: image, payload: Self.bitcoin, in: host)
        view.removeFromSuperview()
        #expect(view.revealState == .visible)
        #expect(view.layer.sublayers?.first?.mask == nil)
        host.rootView.addSubview(view)
        view.layoutIfNeeded()
        #expect(view.revealState == .visible)
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func swiftUIPrimitiveRespectsLayoutAndAccessibility(layout: NativeListTestLayout) async throws {
        _ = try await qr(Self.bitcoin, cache: true)
        let host = try NativeListTestHost(layout: layout) {
            ReceiveQRCodeImage(payload: Self.bitcoin, animatesReveal: true)
                .frame(maxWidth: 380)
                .environment(\.scenePhase, .active)
        }
        defer { host.close() }
        let view = try await waitForNativeView(in: host)
        try await waitForCompletion(view)
        #expect(view.bounds.width > 0)
        #expect(abs(view.bounds.width - view.bounds.height) < 0.001)
        #expect(view.bounds.width <= min(host.rootView.bounds.width, 380))
        #expect(view.revealState == .visible)
        #expect(view.accessibilityIgnoresInvertColors)
        #expect(!view.isUserInteractionEnabled)
        #expect(view.layer.sublayers?.first?.mask == nil)
    }

    @Test
    func sensitiveAndNonReceiveCodesStayStaticByDefault() {
        #expect(!ReceiveQRCodeImage(payload: "static-fixture").animatesReveal)
        #expect(!ReceiveQRCodeImage(payload: "noncached-fixture", cachesRenderedImage: false).animatesReveal)
        #expect(!ReceiveQRCodeImage(payload: "static-fixture").showsBrandMark)
        #expect(
            ReceiveQRCodeImage(
                payload: "receive-fixture",
                showsBrandMark: true
            ).showsBrandMark
        )
        #expect(ReceiveQRCodeBrandMark.sizeRatio == 0.18)
    }

    @Test(arguments: [
        "bitcoin:1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa",
        "ethereum:0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045@1?value=1000000000000000",
        "ethereum:0xdAC17F958D2ee523a2206206994597C13D831ec7@1/transfer?address=0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045&uint256=1000000",
        "solana:So11111111111111111111111111111111111111112",
        "T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb",
        "xrp:rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh?dt=12345"
    ])
    func originalPaymentPayloadRemainsExactlyScannable(payload: String) async throws {
        let image = try await qr(payload)
        let view = ReceiveQRCodeRevealUIView()
        view.configure(image: image, payload: payload, animated: false)
        let imageLayer = try #require(view.layer.sublayers?.first)
        #expect((imageLayer.contents as AnyObject?) === image)
        #expect(imageLayer.mask == nil)
        #expect(try decodedPayload(image) == payload)
    }

    @Test(arguments: [
        "bitcoin:1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa",
        "ethereum:0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045@1?value=1000000000000000",
        "ethereum:0xdAC17F958D2ee523a2206206994597C13D831ec7@1/transfer?address=0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045&uint256=1000000",
        "solana:So11111111111111111111111111111111111111112",
        "T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb",
        "xrp:rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh?dt=12345"
    ], [ColorScheme.light, .dark])
    func brandedPaymentPayloadRemainsExactlyScannable(
        payload: String, colorScheme: ColorScheme
    ) async throws {
        _ = try await qr(payload, cache: true)
        for size: CGFloat in [220, 380] {
            let renderer = ImageRenderer(
                content: ReceiveQRCodeImage(
                    payload: payload,
                    contentPadding: 0,
                    showsBrandMark: true
                )
                .frame(width: size, height: size)
                .background(WalletTheme.qrCodeSurface)
                .environment(\.colorScheme, colorScheme)
            )
            renderer.scale = 2
            let brandedImage = try #require(renderer.cgImage)
            #expect(try decodedPayload(brandedImage) == payload)
            if payload == Self.bitcoin, size == 380 {
                let appearance = colorScheme == .light ? "light" : "dark"
                let file = FileManager.default.temporaryDirectory
                    .appendingPathComponent("oath-receive-qr-\(appearance).png")
                try #require(UIImage(cgImage: brandedImage).pngData()).write(to: file)
                print("Receive QR branding preview: \(file.path)")
            }
        }
    }

    @Test
    func appearanceUpdatesTheSamePayloadWithoutRestartingReveal() async throws {
        let source = try await qr(Self.bitcoin)
        let light = ReceiveQRCodeAppearance.image(source, colorScheme: .light)
        let dark = ReceiveQRCodeAppearance.image(source, colorScheme: .dark)
        #expect(light.width == source.width && dark.width == source.width)
        #expect(light.shouldInterpolate == source.shouldInterpolate)
        #expect(dark.shouldInterpolate == source.shouldInterpolate)
        let lightBytes = try #require(light.dataProvider?.data) as Data
        let darkBytes = try #require(dark.dataProvider?.data) as Data
        #expect(lightBytes[0] > 240)
        #expect(darkBytes[0] < 50)
        let view = ReceiveQRCodeRevealUIView()
        view.configure(image: light, payload: Self.bitcoin, animated: false)
        view.configure(image: dark, payload: Self.bitcoin, animated: true)
        #expect(view.revealState == .visible)
        let layer = try #require(view.layer.sublayers?.first)
        #expect((layer.contents as AnyObject?) === dark)
        #expect(layer.mask == nil)
        #expect(try decodedPayload(dark) == Self.bitcoin)
    }

    @Test
    func rendererPreservesCacheAndQuietZone() async throws {
        let payload = "ethereum:0x0000000000000000000000000000000000000001@1"
        let first = try await qr(payload, cache: true)
        let cached = try await qr(payload, cache: true)
        #expect(first === cached)
        let moduleScale: Int
        if #available(iOS 26.0, *) { moduleScale = 16 } else { moduleScale = 1 }
        // Apple can compress numeric segments more tightly than the legacy
        // byte-only encoder. Check valid QR geometry, not equal version sizes.
        #expect(first.width.isMultiple(of: moduleScale))
        let symbolModules = first.width / moduleScale - 8
        #expect((21...177).contains(symbolModules))
        #expect((symbolModules - 21).isMultiple(of: 4))
        #expect(first.width <= 185 * 16)
        #expect(first.bitsPerPixel == 8)
        #expect(first.shouldInterpolate == (moduleScale > 1))
        let data = try #require(first.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        let border = 4 * moduleScale
        var quietZoneIsWhite = true
        for y in 0..<first.height {
            for x in 0..<first.width {
                if x < border || y < border || x >= first.width - border || y >= first.height - border {
                    quietZoneIsWhite = quietZoneIsWhite && bytes[y * first.bytesPerRow + x] == 255
                }
            }
        }
        #expect(quietZoneIsWhite)
        let uncached = try await qr(payload)
        #expect(uncached !== cached, "Noncached requests must bypass an existing shared entry")
        #expect(ReceiveQRCodeMemoryCache.shared.image(for: payload) === cached)
        let privateFixture = "uncached-public-test-fixture"
        _ = try await qr(privateFixture)
        #expect(ReceiveQRCodeMemoryCache.shared.image(for: privateFixture) == nil)
        let oversized = await ReceiveQRCodeRenderer.shared.image(for: String(repeating: "x", count: 2_332))
        #expect(oversized == nil)
    }

    @Test(arguments: [
        "https://example.org/pay?label=مرحبا", "https://example.org/日本語", "public-fixture-🔑",
        String(repeating: "a", count: 500)
    ])
    func rendererRoundTripsUTF8AndLongPayloads(payload: String) async throws {
        #expect(try decodedPayload(try await qr(payload)) == payload)
        let legacy = try #require(ReceiveQRCodeRenderer.legacyImage(for: payload))
        #expect(!legacy.shouldInterpolate)
        #expect(!ReceiveQRCodeAppearance.image(legacy, colorScheme: .dark).shouldInterpolate)
        #expect(try decodedPayload(legacy) == payload)
    }

    @Test
    func nativeRoundedArtworkKeepsFinderStructureAndSmoothEdges() async throws {
        if #available(iOS 26.0, *) {
            let image = try await qr(Self.bitcoin)
            let legacy = try #require(ReceiveQRCodeRenderer.legacyImage(for: Self.bitcoin))
            // Assert the real raster, not filter settings: a failed native path
            // falling back to the square encoder must fail this check.
            #expect(image.width == legacy.width * 16)
            let data = try #require(image.dataProvider?.data)
            let bytes = try #require(CFDataGetBytePtr(data))
            let border = 4 * 16
            func pixel(_ x: Int, _ y: Int) -> UInt8 {
                bytes[(border + y) * image.bytesPerRow + border + x]
            }
            #expect(pixel(0, 0) > 240, "The finder corner must be rounded")
            #expect(pixel(56, 8) < 10, "Preserve the outer finder ring")
            #expect(pixel(24, 56) > 240, "Preserve the finder separator")
            #expect(pixel(56, 56) < 10, "Preserve the finder center")
            let hasSmoothEdges = (0..<112).contains { y in
                (0..<112).contains { x in pixel(x, y) > 0 && pixel(x, y) < 255 }
            }
            #expect(hasSmoothEdges, "Rounded contours must retain native antialiasing")
            #expect(try decodedPayload(image) == Self.bitcoin)
        }
    }

    @Test
    func uncachedRenderingKeepsMainActorResponsive() async throws {
        var finished = false
        let work = Task { @MainActor in
            defer { finished = true }
            var longest = Duration.zero
            for index in 0..<60 {
                let start = ContinuousClock.now
                let image = await ReceiveQRCodeRenderer.shared.image(
                    for: "ethereum:0x0000000000000000000000000000000000000001@1?value=\(index)",
                    cacheResult: false
                )
                #expect(image != nil)
                longest = max(longest, start.duration(to: .now))
            }
            print("QR_MAX_RENDER=\(longest)")
            #expect(longest < .milliseconds(500))
        }
        var ticks = 0
        var longestGap = Duration.zero
        while !finished {
            let start = ContinuousClock.now
            try await Task.sleep(for: .milliseconds(5))
            longestGap = max(longestGap, start.duration(to: .now))
            ticks += 1
        }
        await work.value
        print("QR_MAIN_HEARTBEATS=\(ticks) MAX_GAP=\(longestGap)")
        #expect(ticks >= 5)
        #expect(longestGap < .milliseconds(250))
    }

    private func qr(_ payload: String, cache: Bool = false) async throws -> CGImage {
        try #require(await ReceiveQRCodeRenderer.shared.image(for: payload, cacheResult: cache))
    }

    private func decodedPayload(_ image: CGImage) throws -> String? {
        let detector = try #require(CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: CIContext(),
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ))
        let dimension = max(768, image.width)
        let bitmap = try #require(CGContext(
            data: nil, width: dimension, height: dimension, bitsPerComponent: 8,
            bytesPerRow: dimension, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        bitmap.interpolationQuality = .none
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
        let scaled = try #require(bitmap.makeImage())
        return (detector.features(in: CIImage(cgImage: scaled)).first as? CIQRCodeFeature)?.messageString
    }

    private func mount(
        image: CGImage, payload: String, animated: Bool = true,
        in host: NativeListTestHost
    ) -> ReceiveQRCodeRevealUIView {
        let view = ReceiveQRCodeRevealUIView()
        view.configure(image: image, payload: payload, animated: animated)
        view.frame = CGRect(x: 20, y: 80, width: 300, height: 300)
        host.rootView.addSubview(view)
        view.layoutIfNeeded()
        return view
    }

    private func waitForCompletion(_ view: ReceiveQRCodeRevealUIView) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while view.revealState != .visible, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(view.revealState == .visible, "Native reveal did not finish")
    }

    private func waitForNativeView(in host: NativeListTestHost) async throws -> ReceiveQRCodeRevealUIView {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            host.rootView.layoutIfNeeded()
            if let view = findNativeView(in: host.rootView) { return view }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try #require(findNativeView(in: host.rootView))
    }

    private func findNativeView(in view: UIView) -> ReceiveQRCodeRevealUIView? {
        if let qrView = view as? ReceiveQRCodeRevealUIView { return qrView }
        for child in view.subviews {
            if let qrView = findNativeView(in: child) { return qrView }
        }
        return nil
    }
}

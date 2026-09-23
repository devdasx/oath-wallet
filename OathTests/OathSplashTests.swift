import CoreHaptics
import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor
@Suite(.serialized)
struct OathSplashTests {
    @Test
    func realAuthenticationWaitsForSplashAndAnActiveScene() async throws {
        let database = try WalletDatabase.temporary()
        try await database.disableAppLock()
        let settings = try await database.walletSecuritySettings()
        let applicationSettings = WalletSettingsStore(database: database, initialSettings: .default)
        let probe = SplashAuthenticationGateProbe()
        let host = try NativeListTestHost {
            SplashAuthenticationGateHost(database: database, settings: settings, probe: probe)
                .environment(applicationSettings)
        }
        defer { host.close() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(probe.grants == 0, "Even an unprotected wallet must wait for the launch hand-off")
        probe.phase = .inactive
        probe.ready = true
        try await Task.sleep(for: .milliseconds(150))
        #expect(probe.grants == 0, "Completing a cancelled splash in background must not start authentication")
        probe.phase = .active
        for _ in 0..<100 {
            if probe.grants > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(probe.grants == 1)
        probe.phase = .inactive
        probe.phase = .active
        try await Task.sleep(for: .milliseconds(80))
        #expect(probe.grants == 1, "Face ID's activation must not repeat the initial authentication")
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func suppliedAssetsAndNativeLaunchConfiguration(style: UIUserInterfaceStyle) throws {
        let launch = try #require(Bundle.main.infoDictionary?["UILaunchScreen"] as? [String: Any])
        #expect(launch["UIColorName"] as? String == "LaunchBackground")
        #expect(launch["UIImageName"] as? String == "OathMark")
        #expect(launch["UIImageRespectsSafeAreaInsets"] as? Bool == false)
        #expect(Bundle.main.infoDictionary?["UILaunchStoryboardName"] == nil)
        let traits = UITraitCollection(userInterfaceStyle: style)
        let mark = try #require(UIImage(named: "OathMark", in: .main, compatibleWith: traits))
        #expect(mark.size == CGSize(width: 128, height: 86))
        let color = try #require(UIColor(named: "LaunchBackground")?.resolvedColor(with: traits))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #expect(color.getRed(&r, green: &g, blue: &b, alpha: &a))
        #expect(abs(r - (style == .dark ? 0 : 0.949)) < 0.0001)
        #expect(abs(g - (style == .dark ? 0 : 0.949)) < 0.0001)
        #expect(abs(b - (style == .dark ? 0 : 0.969)) < 0.0001)
        #expect(a == 1)
        let url = try #require(Bundle.main.url(forResource: "OathSplash", withExtension: "ahap"))
        let pattern = try CHHapticPattern(contentsOf: url)
        #expect(abs(pattern.duration - 0.85) < 0.001)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let entries = try #require(json["Pattern"] as? [[String: Any]])
        let transients = entries.compactMap { $0["Event"] as? [String: Any] }
            .filter { $0["EventType"] as? String == "HapticTransient" }
        #expect(transients.compactMap { $0["Time"] as? Double } == [0.3, 0.37])
    }

    @Test
    func normalTimelineHoldsInhalesRevealsThenEnablesContent() async throws {
        let clock = SplashTestClock()
        let haptics = SplashHapticRecorder()
        let state = OathSplashPresentation(haptics: haptics, waitUntil: clock.wait)
        #expect(state.artwork.mark.opacity == 1 && state.artwork.cover.opacity == 1)
        #expect(state.homeOpacity == 0 && state.homeScale(reduceMotion: false) == 1.06)
        let task = Task { await state.run(reduceMotion: false) }
        await clock.reachWait(1)
        #expect(!state.finished)
        #expect(state.artwork.mark.animation(forKey: "oath.scale") != nil)
        #expect(haptics.events == ["prepare"])
        clock.advance()
        await clock.reachWait(2)
        #expect(haptics.events == ["prepare", "play"])
        #expect(!state.finished)
        clock.advance()
        await clock.reachWait(3)
        #expect(state.homeOpacity == 1)
        #expect(!state.finished)
        #expect(clock.deadlines[0].duration(to: clock.deadlines[1]) == .milliseconds(300))
        #expect(clock.deadlines[1].duration(to: clock.deadlines[2]) == .milliseconds(560))
        clock.advance()
        await task.value
        #expect(state.finished && state.homeScale(reduceMotion: false) == 1)
        #expect(haptics.events.last == "stop")
        await state.run(reduceMotion: false)
        #expect(clock.deadlines.count == 3, "Foregrounding or root updates must not replay the splash")
    }

    @Test
    func reducedMotionNeverScalesAndUsesOnlyOneSoftImpact() async {
        let clock = SplashTestClock()
        let haptics = SplashHapticRecorder()
        let state = OathSplashPresentation(haptics: haptics, waitUntil: clock.wait)
        #expect(state.homeScale(reduceMotion: true) == 1)
        let task = Task { await state.run(reduceMotion: true) }
        await clock.reachWait(1)
        clock.advance()
        await clock.reachWait(2)
        #expect(state.homeScale(reduceMotion: false) == 1)
        #expect(state.artwork.mark.animation(forKey: "oath.scale") == nil)
        #expect(CATransform3DIsIdentity(state.artwork.mark.transform))
        #expect(state.homeOpacity == 1)
        #expect(haptics.events == ["prepare", "reduced"])
        #expect(clock.deadlines[0].duration(to: clock.deadlines[1]) == .milliseconds(320))
        clock.advance()
        await task.value
        #expect(state.finished && haptics.events.last == "stop")
    }

    @Test(arguments: [1, 2])
    func cancellationRemovesCoverStopsHapticsAndCannotReplay(atWait: Int) async {
        let clock = SplashTestClock()
        let haptics = SplashHapticRecorder()
        let state = OathSplashPresentation(haptics: haptics, waitUntil: clock.wait)
        let task = Task { await state.run(reduceMotion: false) }
        await clock.reachWait(1)
        if atWait == 2 { clock.advance(); await clock.reachWait(2) }
        task.cancel()
        clock.advance()
        await task.value
        #expect(state.finished && state.homeOpacity == 1)
        #expect(state.artwork.mark.animationKeys()?.isEmpty != false)
        #expect(state.artwork.cover.animationKeys()?.isEmpty != false)
        #expect(haptics.events.last == "stop")
        let eventCount = haptics.events.count
        await state.run(reduceMotion: false)
        #expect(haptics.events.count == eventCount)
    }

    @Test
    func unsupportedHapticsUseExactFallbackBeatsAndStopCancelsEcho() async {
        let clock = SplashTestClock()
        let driver = SplashPatternRecorder(fails: true)
        var impacts: [SplashImpact] = []
        let haptics = SplashHaptics(driver: driver, canPlay: { true }, prepareFallback: {},
                                   impact: { impacts.append($0) }, waitUntil: clock.wait)
        haptics.prepare()
        haptics.play()
        await clock.reachWait(1)
        #expect(impacts == [.inhale])
        clock.advance()
        await clock.reachWait(2)
        #expect(impacts == [.inhale, .seal])
        #expect(clock.deadlines[0].duration(to: clock.deadlines[1]) == .milliseconds(70))
        haptics.stop()
        clock.advance()
        for _ in 0..<10 { await Task.yield() }
        #expect(impacts == [.inhale, .seal])
        haptics.play()
        #expect(impacts.count == 2)
    }

    @Test
    func hapticPreferenceAndInactiveLaunchAreSilent() async {
        var allowed = false
        var impacts: [SplashImpact] = []
        let driver = SplashPatternRecorder(fails: false)
        let haptics = SplashHaptics(driver: driver, canPlay: { allowed }, prepareFallback: {},
                                   impact: { impacts.append($0) })
        haptics.prepare(); haptics.play(); haptics.playReduced()
        #expect(driver.prepares == 0 && driver.plays == 0 && impacts.isEmpty)
        allowed = true
        haptics.prepare(); haptics.play(); haptics.play()
        #expect(driver.prepares == 1 && driver.plays == 1 && impacts.isEmpty)
        haptics.stop()
        #expect(driver.stops == 1)
    }

    @Test
    func nativeRendererInterpolatesShrinkAndBurstWithoutStateUpdates() async throws {
        let state = OathSplashPresentation(haptics: SplashHapticRecorder())
        let host = try NativeListTestHost {
            Color.clear.overlay { OathSplashArtwork(presentation: state).ignoresSafeArea() }
        }
        defer { state.artwork.stop(); host.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.rootView.layoutIfNeeded()
        let start = CACurrentMediaTime()
        state.artwork.schedule(reduceMotion: false, at: start)
        CATransaction.flush()
        var shrink: [CGFloat] = []
        var burst: [CGFloat] = []
        while CACurrentMediaTime() - start < 1.17 {
            try await Task.sleep(for: .milliseconds(8))
            let time = CACurrentMediaTime() - start
            let layer = try #require(state.artwork.mark.presentation())
            let scale = layer.transform.m11
            if (0.38...0.63).contains(time) { shrink.append(scale) }
            if (0.72...1.08).contains(time) { burst.append(scale) }
        }
        #expect(Set(shrink.map { Int(($0 * 10_000).rounded()) }).count >= 8,
                "The render server must draw intermediate sizes, not jump between the anchors")
        #expect(try #require(shrink.first) > #require(shrink.last))
        #expect(try #require(burst.last) > #require(burst.first) + 1)
        #expect(shrink.allSatisfy { (0.899...1.001).contains($0) })
        #expect(state.artwork.mark.opacity == 0 && state.artwork.cover.opacity == 0)
        #expect(!state.hasStarted, "Rendering ran without a SwiftUI state timeline or per-frame updates")
    }

    @Test(arguments: [CGSize(width: 320, height: 568), CGSize(width: 393, height: 852), CGSize(width: 440, height: 956)])
    func firstFrameIsFullScreenCenteredAtSuppliedSize(size: CGSize) async throws {
        let state = OathSplashPresentation(haptics: SplashHapticRecorder())
        let host = try NativeListTestHost(size: size) {
            Color.clear.overlay { OathSplashArtwork(presentation: state).ignoresSafeArea() }
        }
        defer { host.close() }
        try await Task.sleep(for: .milliseconds(120))
        host.rootView.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            host.rootView.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        let cg = try #require(image.cgImage)
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(size.width * size.height) * 4)
        defer { bytes.deallocate() }
        let context = try #require(CGContext(data: bytes, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(origin: .zero, size: size))
        var minX = cg.width, maxX = 0, minY = cg.height, maxY = 0
        for y in 0..<cg.height {
            for x in 0..<cg.width {
                let i = (y * cg.width + x) * 4
                if (0..<3).contains(where: { abs(Int(bytes[i + $0]) - Int(bytes[$0])) > 20 }) {
                    minX = min(x, minX); maxX = max(x, maxX)
                    minY = min(y, minY); maxY = max(y, maxY)
                }
            }
        }
        #expect(abs(CGFloat(minX + maxX + 1) / 2 - size.width / 2) <= 1)
        #expect(abs(CGFloat(minY + maxY + 1) / 2 - size.height / 2) <= 1)
        #expect((126...130).contains(maxX - minX + 1))
        #expect((84...88).contains(maxY - minY + 1))
    }
}

@MainActor @Observable
private final class SplashAuthenticationGateProbe {
    var ready = false
    var phase: ScenePhase = .active
    var grants = 0
}

private struct SplashAuthenticationGateHost: View {
    let database: WalletDatabase
    let settings: WalletSecuritySettings
    let probe: SplashAuthenticationGateProbe
    var body: some View {
        WalletSecurityAuthenticationView(database: database, settings: settings, purpose: .appUnlock) {
            probe.grants += 1
        }
        .environment(\.walletLaunchSplashFinished, probe.ready)
        .environment(\.scenePhase, probe.phase)
    }
}

@MainActor
private final class SplashTestClock {
    var deadlines: [ContinuousClock.Instant] = []
    private var continuation: CheckedContinuation<Void, any Error>?
    func wait(until deadline: ContinuousClock.Instant) async throws {
        deadlines.append(deadline)
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func reachWait(_ count: Int) async {
        for _ in 0..<1000 {
            if deadlines.count >= count && continuation != nil { return }
            await Task.yield()
        }
        Issue.record("Splash did not reach expected deadline")
    }
    func advance() {
        let value = continuation; continuation = nil; value?.resume()
    }
}

@MainActor
private final class SplashHapticRecorder: SplashHapticPlaying {
    var events: [String] = []
    func prepare() { events.append("prepare") }
    func play() { events.append("play") }
    func playReduced() { events.append("reduced") }
    func stop() { events.append("stop") }
}

@MainActor
private final class SplashPatternRecorder: SplashPatternDriving {
    let fails: Bool
    var prepares = 0, plays = 0, stops = 0
    init(fails: Bool) { self.fails = fails }
    func prepare() throws { prepares += 1; if fails { throw CancellationError() } }
    func play() throws { plays += 1; if fails { throw CancellationError() } }
    func stop() { stops += 1 }
}

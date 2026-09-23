import SwiftUI
import Observation
import Synchronization
import Testing
@testable import SendSlideFixture

/// Native animation/layout observations only; no images or recordings.
@MainActor @Suite(.serialized)
struct SendSlideGuidanceTests {
    @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft], [false, true])
    func guidanceRestartsAfterReadinessAndCancelledTouch(direction: LayoutDirection, arrows: Bool) async throws {
        let state = GuidanceProbeState()
        let window = try makeWindow(GuidanceProbe(state: state, arrows: arrows)
            .environment(\.layoutDirection, direction))
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitUntil { !state.widths.isEmpty }

        for _ in 0..<2 {
            state.widths.removeAll()
            state.isActive = true
            try await waitUntil { state.widths.count > 2 }
            #expect(state.widths.max()! - state.widths.min()! > 1,
                    "Guidance must keep cycling after becoming ready or cancelling a touch")
            state.isActive = false
            try await Task.sleep(for: .milliseconds(100))
            state.widths.removeAll()
            try await Task.sleep(for: .milliseconds(250))
            #expect(state.widths.isEmpty, "Inactive guidance must remain static")
        }
    }

    @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft])
    func shimmerRendersIntermediatePhasesForJoinedText(direction: LayoutDirection) async throws {
        let samples = ShimmerRenderSamples()
        let state = GuidanceProbeState()
        let window = try makeWindow(ShimmerRenderProbe(state: state, samples: samples, direction: direction)
            .environment(\.locale, Locale(identifier: direction == .rightToLeft ? "ar" : "en"))
            .environment(\.layoutDirection, direction))
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(100))
        state.isActive = true
        try await waitUntil { samples.snapshot().filter { $0.phase > 0.1 && $0.phase < 0.9 }.count >= 5 }
        let drawn = samples.snapshot().filter { $0.phase > 0.1 && $0.phase < 0.9 }
        #expect(Set(drawn.map { $0.phase }).count >= 5,
                "TextRenderer must receive interpolated shimmer frames, not just identical-looking endpoints")
        let coordinates = try #require(drawn.last?.glyphCenters)
        #expect(coordinates.count > 3)
        #expect(try #require(coordinates.max()) - #require(coordinates.min()) > 0.4,
                "Joined Arabic glyphs must expose distinct physical positions for a traveling shimmer")
    }

    @Test func shimmerTravelsInTheNativeReadingDirectionAndKeepsTextVisible() {
        let phase = (0.25 + 0.28) / 1.56
        let ltr = SendSlideShimmerRenderer(phase: phase, layoutDirection: .leftToRight, isActive: true)
        let rtl = SendSlideShimmerRenderer(phase: phase, layoutDirection: .rightToLeft, isActive: true)
        #expect(ltr.opacity(at: 0.25) > ltr.opacity(at: 0.75))
        #expect(rtl.opacity(at: 0.75) > rtl.opacity(at: 0.25))
        for step in 0...20 {
            let position = Double(step) / 20
            #expect(abs(ltr.opacity(at: position) - rtl.opacity(at: 1 - position)) < 0.0001)
            #expect((0.55...1).contains(ltr.opacity(at: position)))
        }
    }

    private func makeWindow<V: View>(_ content: V) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        return window
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "The native animation did not produce the expected frames within three seconds")
    }
}

@MainActor @Observable private final class GuidanceProbeState {
    var isActive = false
    var widths = [Double]()
}

private struct GuidanceProbe: View {
    let state: GuidanceProbeState
    let arrows: Bool
    var body: some View {
        SendSlideGuidanceCycle(isActive: state.isActive,
            phases: arrows ? [0.0, 1, 2, 3] : [0.0, 1], idlePhase: 0) { phase in
                Color.clear.frame(width: 20 + phase * 20, height: 20)
                    .onGeometryChange(for: Double.self) { $0.size.width } action: { state.widths.append($0) }
            } animation: { _ in .linear(duration: 0.2) }
    }
}

private struct ShimmerRenderProbe: View {
    let state: GuidanceProbeState
    let samples: ShimmerRenderSamples
    let direction: LayoutDirection
    var body: some View {
        SendSlideGuidanceCycle(isActive: state.isActive, phases: [0.0, 1], idlePhase: 0) { phase in
            Text("send.review.slide_action")
                .font(.headline)
                .textRenderer(ObservedShimmerRenderer(phase: phase, direction: direction, samples: samples))
        } animation: { phase in
            phase == 1 ? .linear(duration: 1.8) : .linear(duration: 0).delay(0.65)
        }
    }
}

private final class ShimmerRenderSamples: Sendable {
    struct Sample: Sendable {
        let phase: Double
        let glyphCenters: [Double]
    }
    private let samples = Mutex<[Sample]>([])
    func record(_ value: Sample) { samples.withLock { $0.append(value) } }
    func snapshot() -> [Sample] { samples.withLock { $0 } }
}

private struct ObservedShimmerRenderer: TextRenderer {
    var phase: Double
    let direction: LayoutDirection
    let samples: ShimmerRenderSamples
    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let bounds = layout.reduce(CGRect.null) { $0.union($1.typographicBounds.rect) }
        let centers = layout.flatMap { $0.flatMap { $0.map { Double(($0.typographicBounds.rect.midX - bounds.minX) / bounds.width) } } }
        samples.record(.init(phase: phase, glyphCenters: centers))
        SendSlideShimmerRenderer(phase: phase, layoutDirection: direction, isActive: true)
            .draw(layout: layout, in: &context)
    }
}

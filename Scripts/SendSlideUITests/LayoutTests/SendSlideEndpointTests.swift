import SwiftUI
import Testing
@testable import SendSlideFixture

/// Measures the production thumb transform around the readiness and end-stop
/// boundaries. Tiny finger movements must not cause a discrete size/anchor jump.
@MainActor @Suite(.serialized)
struct SendSlideEndpointTests {
    @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft])
    func heldProgressDoesNotStartCatchUpAnimations(direction: LayoutDirection) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        defer { window.isHidden = true; window.rootViewController = nil }
        var observedProgress: CGFloat?
        var animated = false
        let observe: (CGFloat, Bool) -> Void = { observedProgress = $0; animated = $1 }
        let host = UIHostingController(rootView:
            EndpointTransactionProbe(progress: 0.88, direction: direction, onUpdate: observe))
        window.rootViewController = host
        window.makeKeyAndVisible()
        // Allow the hosting controller's presentation to finish before updates.
        try await Task.sleep(for: .milliseconds(300))

        for progress: CGFloat in [0.9, 0.9999, 1, 0.98, 0.89, 1, 0.5] {
            observedProgress = nil
            host.rootView = EndpointTransactionProbe(progress: progress, direction: direction, onUpdate: observe)
            for _ in 0..<50 {
                window.layoutIfNeeded()
                if observedProgress == progress { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(observedProgress == progress)
            #expect(!animated, "Held progress must update directly, including reversal across 90% and 100%")
        }
    }

    @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft])
    func endpointArtworkIsContinuousInBothDirections(direction: LayoutDirection) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        defer { window.isHidden = true; window.rootViewController = nil }

        for boundary: CGFloat in [0.9, 1] {
            var frames = [CGRect]()
            for progress in [boundary - 0.00001, boundary, boundary - 0.00001] {
                var observedFrame: CGRect?
                window.rootViewController = UIHostingController(rootView:
                    EndpointThumbProbe(progress: progress, direction: direction) { observedFrame = $0 })
                window.makeKeyAndVisible()
                for _ in 0..<50 {
                    window.layoutIfNeeded()
                    if observedFrame != nil { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                frames.append(try #require(observedFrame))
            }
            for (before, after) in zip(frames, frames.dropFirst()) {
                #expect(abs(before.width - after.width) < 0.1,
                        "A 0.003-point movement at \(boundary) must not jump between different thumb sizes")
                #expect(abs(before.minX - after.minX) < 0.1,
                        "Crossing an endpoint boundary must not change the thumb's transform anchor")
                #expect(abs(before.height - after.height) < 0.1)
            }
        }
    }
}

private struct EndpointTransactionProbe: View {
    let progress: CGFloat
    let direction: LayoutDirection
    let onUpdate: (CGFloat, Bool) -> Void

    var body: some View {
        TransactionObservation(progress: progress, onUpdate: onUpdate)
            .frame(width: 52, height: 52)
            .modifier(SendSlideControl.ThumbAppearance(isPressed: true, progress: progress, reduceMotion: false))
            .environment(\.layoutDirection, direction)
    }
}

private struct TransactionObservation: UIViewRepresentable {
    let progress: CGFloat
    let onUpdate: (CGFloat, Bool) -> Void

    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ uiView: UIView, context: Context) {
        onUpdate(progress, context.transaction.animation != nil)
    }
}

private struct EndpointThumbProbe: View {
    let progress: CGFloat
    let direction: LayoutDirection
    let onFrame: (CGRect) -> Void

    var body: some View {
        Circle()
            .frame(width: 52, height: 52)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("track")) } action: { onFrame($0) }
            .modifier(SendSlideControl.ThumbAppearance(isPressed: true, progress: progress, reduceMotion: false))
            .modifier(SendSlideControl.ThumbPlacement(distance: progress * 256))
            .frame(width: 320, height: 64)
            .coordinateSpace(name: "track")
            .environment(\.layoutDirection, direction)
    }
}

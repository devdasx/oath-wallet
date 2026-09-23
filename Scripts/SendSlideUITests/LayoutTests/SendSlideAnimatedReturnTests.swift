import SwiftUI
import Testing
@testable import SendSlideFixture

@MainActor @Suite(.serialized)
struct SendSlideAnimatedReturnTests {
    @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft], [CGFloat(0.45), 1])
    func returnTraversesTheTrackWithoutJumpingOrOvershooting(
        direction: LayoutDirection, startingProgress: CGFloat
    ) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        defer { window.isHidden = true; window.rootViewController = nil }
        let model = ReturnPosition(distance: startingProgress * 256)
        var frames: [CGFloat] = []
        window.rootViewController = UIHostingController(rootView: ReturnProbe(model: model) { frames.append($0) }
            .environment(\.layoutDirection, direction))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let initial = try #require(frames.last)
        frames = [initial]
        withAnimation(.spring(duration: SendSlideControl.Motion.returnDuration(distance: model.distance), bounce: 0)) {
            model.distance = 0
        }
        try await Task.sleep(for: .milliseconds(650))
        let final = try #require(frames.last)
        let expected: CGFloat = direction == .rightToLeft ? 262 : 6
        #expect(abs(final - expected) < 0.5)
        let intermediate = frames.filter { abs($0 - initial) > 1 && abs($0 - final) > 1 }
        #expect(intermediate.count >= 3, "The rendered thumb must visit intermediate positions, not teleport")
        let sign: CGFloat = direction == .rightToLeft ? 1 : -1
        for (before, after) in zip(frames, frames.dropFirst()) {
            #expect((after - before) * sign >= -0.5, "A return must move consistently toward its native starting edge")
            #expect(after >= min(initial, final) - 0.5 && after <= max(initial, final) + 0.5)
        }
    }
}

@MainActor @Observable
private final class ReturnPosition {
    var distance: CGFloat
    init(distance: CGFloat) { self.distance = distance }
}

private struct ReturnProbe: View {
    let model: ReturnPosition
    let onPosition: (CGFloat) -> Void

    var body: some View {
        Color.clear.frame(width: 52, height: 52)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("return-track")).minX } action: { onPosition($0) }
            .modifier(SendSlideControl.ThumbPlacement(distance: model.distance))
            .frame(width: 320, height: 64)
            .coordinateSpace(name: "return-track")
    }
}

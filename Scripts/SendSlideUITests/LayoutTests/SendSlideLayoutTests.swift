import SwiftUI
import Testing
@testable import SendSlideFixture

/// Verifies native rendered placement, not just gesture progress math.
@MainActor @Suite(.serialized)
struct SendSlideLayoutTests {
    @Test func cancelledReturnDurationIsBoundedAndFollowsTravelDistance() {
        let distances: [CGFloat] = [0, 24, 120, 300, 600, 10_000]
        let durations = distances.map { SendSlideControl.Motion.returnDuration(distance: $0) }
        #expect(durations.allSatisfy { $0.isFinite && $0 >= 0.1 && $0 <= 0.4 })
        #expect(durations[0] < durations[1])
        #expect(durations[1] < durations[2])
        #expect(durations[2] < durations[3])
        #expect(zip(durations, durations.dropFirst()).allSatisfy { pair in pair.0 <= pair.1 })
        for invalidDistance: CGFloat in [-1, -.infinity, .infinity, .nan] {
            let duration = SendSlideControl.Motion.returnDuration(distance: invalidDistance)
            #expect(duration.isFinite)
            #expect(duration > 0 && duration <= durations[1],
                    "Invalid or negative geometry must settle quickly, without a long or invalid animation")
        }
    }

    @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft], [false, true])
    func pressedThumbFitsTrackAndDocksWithoutChangingGestureBounds(
        direction: LayoutDirection, reduceMotion: Bool
    ) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil }

        for width: CGFloat in [320, 560] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: 200)
            for progress: CGFloat in [0, 0.5, 0.9, 0.999, 1] {
                var visualFrame: CGRect?
                var gestureFrame: CGRect?
                let host = UIHostingController(rootView: PressedThumbProbe(progress: progress, width: width,
                    direction: direction, reduceMotion: reduceMotion,
                    onVisualFrame: { visualFrame = $0 }, onGestureFrame: { gestureFrame = $0 }))
                window.rootViewController = host
                window.makeKeyAndVisible()
                for _ in 0..<50 {
                    window.layoutIfNeeded()
                    if visualFrame != nil && gestureFrame != nil { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let visual = try #require(visualFrame)
                let hitArea = try #require(gestureFrame)
                #expect(visual.minX >= -0.5 && visual.maxX <= width + 0.5,
                        "The lifted and compressed artwork must remain within the slider")
                #expect(visual.minY >= -0.5 && visual.maxY <= 64.5)
                #expect(abs(hitArea.width - 52) < 0.5 && abs(hitArea.height - 52) < 0.5,
                        "Visual deformation must never change the gesture's footprint")
                let expectedX = direction == .rightToLeft
                    ? width - 58 - progress * (width - 64) : 6 + progress * (width - 64)
                #expect(abs(hitArea.minX - expectedX) < 0.5)

                if reduceMotion {
                    #expect(abs(visual.width - hitArea.width) < 0.5)
                    #expect(abs(visual.height - hitArea.height) < 0.5)
                }
                if progress == 1 {
                    let dockedEdge = direction == .rightToLeft ? visual.minX : visual.maxX
                    let dockEdge = direction == .rightToLeft ? CGFloat(6) : width - 6
                    #expect(abs(dockedEdge - dockEdge) < 0.5,
                            "The compressed handle must keep contact with the semantic trailing dock")
                    if !reduceMotion {
                        #expect(visual.width < hitArea.width,
                                "The endpoint must visibly compress the artwork without compressing its hit area")
                    }
                }
            }
        }
    }

    @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft], [CGFloat(320), 560])
    func readinessCopyKeepsLabelBoundsStable(direction: LayoutDirection, width: CGFloat) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 500)
        defer { window.isHidden = true; window.rootViewController = nil }

        for typeSize: DynamicTypeSize in [.large, .accessibility3] {
            var labelFrame: CGRect?
            let observe: (CGRect) -> Void = { labelFrame = $0 }
            let host = UIHostingController(rootView: LabelProbe(progress: 0, isReady: false,
                width: width, direction: direction, typeSize: typeSize, onFrame: observe))
            window.rootViewController = host
            window.makeKeyAndVisible()
            for _ in 0..<50 {
                window.layoutIfNeeded()
                if labelFrame != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let initialFrame = try #require(labelFrame)
            #expect(initialFrame.height > 0)
            for progress: CGFloat in [0.35, 0.89, 0.9, 1, 0.89, 0] {
                host.rootView = LabelProbe(progress: progress, isReady: progress >= 0.9,
                    width: width, direction: direction, typeSize: typeSize, onFrame: observe)
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
                let frame = try #require(labelFrame)
                #expect(abs(frame.width - initialFrame.width) < 1)
                #expect(abs(frame.height - initialFrame.height) < 1,
                        "The ready label must not resize the track under the user's finger")
            }
        }
    }

    @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft], [CGFloat(320), 560])
    func thumbStaysInsideTrackAndMovesTowardTrailing(direction: LayoutDirection, width: CGFloat) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 200)
        defer { window.isHidden = true; window.rootViewController = nil }

        let thumbSize: CGFloat = 52
        let travel = width - thumbSize - 12
        var thumbFrame: CGRect?
        let host = UIHostingController(rootView: ThumbProbe(distance: 0, width: width,
            direction: direction, onFrame: { thumbFrame = $0 }))
        window.rootViewController = host
        window.makeKeyAndVisible()
        for progress: CGFloat in [0, 0.25, 0.5, 0.9, 1, 0.5, 0] {
            thumbFrame = nil
            host.rootView = ThumbProbe(distance: progress * travel, width: width,
                direction: direction, onFrame: { thumbFrame = $0 })
            for _ in 0..<50 {
                window.layoutIfNeeded()
                if thumbFrame != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let frame = try #require(thumbFrame)
            let expectedX = direction == .rightToLeft
                ? width - 6 - thumbSize - progress * travel : 6 + progress * travel
            #expect(abs(frame.minX - expectedX) < 1)
            #expect(frame.minX >= 6 - 0.5)
            #expect(frame.maxX <= width - 6 + 0.5)
            #expect(abs(frame.width - thumbSize) < 1)
        }
    }

    private struct ThumbProbe: View {
        let distance: CGFloat
        let width: CGFloat
        let direction: LayoutDirection
        let onFrame: (CGRect) -> Void

        var body: some View {
            Color.clear
                .frame(width: 52, height: 52)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("track")) } action: { onFrame($0) }
                .modifier(SendSlideControl.ThumbPlacement(distance: distance))
                .frame(width: width, height: 64)
                .coordinateSpace(name: "track")
                .environment(\.layoutDirection, direction)
        }
    }

    private struct PressedThumbProbe: View {
        let progress: CGFloat
        let width: CGFloat
        let direction: LayoutDirection
        let reduceMotion: Bool
        let onVisualFrame: (CGRect) -> Void
        let onGestureFrame: (CGRect) -> Void

        var body: some View {
            Circle()
                .frame(width: 52, height: 52)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("track")) } action: { onVisualFrame($0) }
                .modifier(SendSlideControl.ThumbAppearance(isPressed: true,
                    progress: progress, reduceMotion: reduceMotion))
                .overlay {
                    Color.clear
                        .contentShape(Circle())
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("track")) } action: { onGestureFrame($0) }
                }
                .modifier(SendSlideControl.ThumbPlacement(distance: progress * (width - 64)))
                .frame(width: width, height: 64)
                .coordinateSpace(name: "track")
                .environment(\.layoutDirection, direction)
        }
    }

    private struct LabelProbe: View {
        let progress: CGFloat
        let isReady: Bool
        let width: CGFloat
        let direction: LayoutDirection
        let typeSize: DynamicTypeSize
        let onFrame: (CGRect) -> Void

        var body: some View {
            SendSlideLabel(title: "send.review.slide_action", isAnimating: false,
                           progress: progress, isReadyToRelease: isReady)
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("label")) } action: { onFrame($0) }
                .frame(width: width - 168)
                .coordinateSpace(name: "label")
                .environment(\.layoutDirection, direction)
                .environment(\.locale, Locale(identifier: direction == .rightToLeft ? "ar" : "en"))
                .environment(\.dynamicTypeSize, typeSize)
        }
    }
}

import SwiftUI

/// Both instructions share their measured footprint, so readiness cannot resize
/// the track or move its endpoints while a finger is down.
struct SendSlideLabel: View {
    let title: LocalizedStringKey
    let isAnimating: Bool
    var progress: CGFloat = 0
    var isReadyToRelease = false

    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var shouldAnimate: Bool {
        isAnimating && !reduceMotion && contrast != .increased
    }

    var body: some View {
        ZStack {
            idleInstruction
                .opacity(isReadyToRelease ? 0 : max(0, 1 - Double(progress) / 0.55))
                .accessibilityHidden(isReadyToRelease)
            Text("send.review.slide_release")
                .opacity(isReadyToRelease ? 1 : 0)
                .accessibilityHidden(!isReadyToRelease)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: isReadyToRelease)
    }

    private var idleInstruction: some View {
        SendSlideGuidanceCycle(isActive: shouldAnimate, phases: [0.0, 1.0], idlePhase: 0) { phase in
            Text(title)
                .textRenderer(SendSlideShimmerRenderer(
                    phase: phase,
                    layoutDirection: layoutDirection,
                    isActive: shouldAnimate
                ))
        } animation: { phase in
            // Reset off-text, so the highlight never travels backwards.
            phase == 1 ? .linear(duration: 1.8) : .linear(duration: 0).delay(0.65)
        }
    }
}

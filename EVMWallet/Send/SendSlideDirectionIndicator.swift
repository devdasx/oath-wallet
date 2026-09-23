import SwiftUI

/// Three native directional symbols, ordered from semantic leading to trailing.
/// Both the glyphs and the highlight sequence follow the system's layout direction.
struct SendSlideDirectionIndicator: View {
    let isAnimating: Bool
    let symbolSize: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shouldAnimate: Bool { isAnimating && !reduceMotion }

    var body: some View {
        SendSlideGuidanceCycle(isActive: shouldAnimate, phases: [0, 1, 2, 3], idlePhase: 3) { phase in
            HStack(spacing: symbolSize * 0.12) {
                ForEach(0..<3) { index in
                    Image(systemName: "chevron.forward")
                        .opacity(shouldAnimate ? (phase == index ? 1 : phase == 3 ? 0.65 : 0.32) : 1)
                        .scaleEffect(!shouldAnimate ? 1 : phase == index ? 1.06 : 0.9)
                }
            }
        } animation: { phase in
            .easeInOut(duration: phase == 3 ? 0.6 : 0.24)
        }
        .font(.system(size: symbolSize, weight: .semibold))
        .symbolRenderingMode(.monochrome)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

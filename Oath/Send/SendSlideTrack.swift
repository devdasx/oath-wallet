import SwiftUI

/// Deepens the entire existing glass surface uniformly as the thumb advances.
struct SendSlideTrack: View {
    let color: Color
    let progress: CGFloat
    let isComplete: Bool

    var body: some View {
        Capsule()
            .fill(color)
            .walletRegularGlassEffect(tint: color, in: Capsule())
            .brightness(-0.12 * Double(isComplete ? 1 : min(1, max(0, progress))))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

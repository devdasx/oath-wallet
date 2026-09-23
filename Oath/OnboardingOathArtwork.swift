import SwiftUI

/// The supplied Oath icon, kept upright and unclipped in either reading direction.
struct OnboardingOathArtwork: View {
    var size: CGFloat = 248

    var body: some View {
        OnboardingBrandMark(size: size * 0.87)
            .frame(width: size, height: size * 1.06)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .environment(\.layoutDirection, .leftToRight)
    }
}

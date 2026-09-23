import SwiftUI

/// Fades already-shaped glyphs in a traveling wave, without gradients or blur.
/// Drawing the original slices preserves Arabic joining and native bidi layout.
struct SendSlideShimmerRenderer: TextRenderer {
    var phase: Double
    let layoutDirection: LayoutDirection
    let isActive: Bool

    // Explicit conformance keeps this renderer available on the iOS 18 target.
    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        guard isActive else {
            for line in layout { context.draw(line) }
            return
        }

        let bounds = layout.reduce(CGRect.null) { $0.union($1.typographicBounds.rect) }
        guard bounds.width.isFinite, bounds.width > 0 else {
            for line in layout { context.draw(line) }
            return
        }

        for line in layout {
            for run in line {
                for slice in run {
                    let x = (slice.typographicBounds.rect.midX - bounds.minX) / bounds.width
                    var glyphContext = context
                    // Keep the whole instruction readable throughout the sweep.
                    glyphContext.opacity *= opacity(at: Double(x))
                    glyphContext.draw(slice)
                }
            }
        }
    }

    /// Physical text coordinates map once to native leading-to-trailing travel.
    func opacity(at horizontalPosition: Double) -> Double {
        let waveCenter = -0.28 + min(1, max(0, phase)) * 1.56
        let leadingPosition = layoutDirection == .rightToLeft ? 1 - horizontalPosition : horizontalPosition
        let intensity = max(0, 1 - abs(leadingPosition - waveCenter) / 0.28)
        let fade = intensity * intensity * (3 - 2 * intensity)
        return 0.55 + 0.45 * fade
    }
}

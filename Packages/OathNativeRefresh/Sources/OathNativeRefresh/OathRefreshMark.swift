import SwiftUI

/// Exact vector construction from the supplied solid ink/white SVGs:
/// viewBox 82 222 860 580, two 230-radius rings with 120-wide strokes;
/// the crossing gaps use the SVG's 164-wide, half-clipped masks.
struct OathRefreshMark: Shape {
    private static let outline: Path = {
        // Boolean paths flatten curves. Resolve once at higher precision so
        // crossing edges stay faithful before scaling to the small indicator.
        let precision = CGAffineTransform(scaleX: 8, y: 8)
        func ring(centerX: CGFloat, width: CGFloat) -> Path {
            let outer = 230 + width / 2, inner = 230 - width / 2
            // Build the annulus directly: stroking a flattened curve subtly
            // changes its inner/outer silhouette at the crossing masks.
            return Path(ellipseIn: CGRect(x: centerX - outer, y: 512 - outer,
                                          width: outer * 2, height: outer * 2))
                .applying(precision)
                .subtracting(Path(ellipseIn: CGRect(x: centerX - inner, y: 512 - inner,
                                                   width: inner * 2, height: inner * 2)).applying(precision))
        }
        let top = Path(CGRect(x: 0, y: 0, width: 1024, height: 512)).applying(precision)
        let bottom = Path(CGRect(x: 0, y: 512, width: 1024, height: 512)).applying(precision)
        let left = ring(centerX: 372, width: 120)
            .subtracting(ring(centerX: 652, width: 164).intersection(bottom))
        let right = ring(centerX: 652, width: 120)
            .subtracting(ring(centerX: 372, width: 164).intersection(top))
        return left.union(right).applying(CGAffineTransform(scaleX: 1 / 8, y: 1 / 8))
    }()

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 860, rect.height / 580)
        guard scale.isFinite, scale > 0 else { return Path() }
        return Self.outline.applying(CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale,
            tx: rect.midX - 512 * scale, ty: rect.midY - 512 * scale
        ))
    }
}

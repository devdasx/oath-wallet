import CoreGraphics

/// Compatible native paths for the finite circle-to-check morph.
enum RefreshRingGeometry {
    /// Start at twelve o'clock and use four cubic segments for both shapes.
    static var circle: CGPath {
        let p = CGMutablePath()
        let k: CGFloat = 6.6274
        p.move(to: CGPoint(x: 14, y: 2))
        p.addCurve(to: CGPoint(x: 26, y: 14), control1: CGPoint(x: 14 + k, y: 2), control2: CGPoint(x: 26, y: 14 - k))
        p.addCurve(to: CGPoint(x: 14, y: 26), control1: CGPoint(x: 26, y: 14 + k), control2: CGPoint(x: 14 + k, y: 26))
        p.addCurve(to: CGPoint(x: 2, y: 14), control1: CGPoint(x: 14 - k, y: 26), control2: CGPoint(x: 2, y: 14 + k))
        p.addCurve(to: CGPoint(x: 14, y: 2), control1: CGPoint(x: 2, y: 14 - k), control2: CGPoint(x: 14 - k, y: 2))
        return p
    }

    static var check: CGPath {
        let p = CGMutablePath()
        let points = [CGPoint(x: 4, y: 14), CGPoint(x: 7.5, y: 17.5), CGPoint(x: 11, y: 21),
                      CGPoint(x: 17.5, y: 14), CGPoint(x: 24, y: 7)]
        p.move(to: points[0])
        for (a, b) in zip(points, points.dropFirst()) {
            p.addCurve(to: b,
                control1: CGPoint(x: a.x + (b.x - a.x) / 3, y: a.y + (b.y - a.y) / 3),
                control2: CGPoint(x: a.x + (b.x - a.x) * 2 / 3, y: a.y + (b.y - a.y) * 2 / 3))
        }
        return p
    }
}

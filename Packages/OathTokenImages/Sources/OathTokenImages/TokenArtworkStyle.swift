import CoreGraphics
import SwiftUI
import OathDiagnostics

/// Immutable presentation metadata travels with the decoded original through
/// the existing image cache. It never identifies a token or changes its bytes.
public struct TokenArtworkColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public static let neutral = Self(red: 0.92, green: 0.93, blue: 0.95)
    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }

    private var luminance: Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
    func contrast(with other: Self) -> Double {
        (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
    }
    /// An uncontained, single-color mark would disappear on its own color.
    /// Keep its hue but move the background toward white or black for contrast.
    var contrastingShade: Self {
        // Pick the endpoint with more contrast, including bright green/yellow
        // whose numeric RGB values can look dark while their luminance is high.
        let end = luminance < 0.179 ? 1.0 : 0.0
        for step in 14...20 {
            let amount = Double(step) / 20
            let result = Self(red: red + (end - red) * amount,
                              green: green + (end - green) * amount,
                              blue: blue + (end - blue) * amount)
            if contrast(with: result) >= 3 { return result }
        }
        return Self(red: end, green: end, blue: end)
    }
}

public enum TokenArtworkStyle {
    public static let cornerRadiusFraction: CGFloat = 0.22
}

/// Native presentation only: the source mark stays intact, including SVG paths.
public struct TokenArtworkView: View {
    private let artwork: ArtworkImage
    private let size: CGFloat
    public init(_ artwork: ArtworkImage, size: CGFloat) { self.artwork = artwork; self.size = size }
    public var body: some View {
        ZStack {
            artwork.backgroundColor.color
            ArtworkImageView(artwork)
                // A tiny bleed hides provider matte fringes at the edge of
                // circular PNGs without extracting/recoloring their symbols.
                .scaleEffect(1.02)
                // Retain the app's existing token crop. It also excludes a
                // provider's white square corners around a circular badge.
                .clipShape(Circle(), style: FillStyle(antialiased: true))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * TokenArtworkStyle.cornerRadiusFraction,
                                    style: .continuous), style: FillStyle(antialiased: true))
        .accessibilityHidden(true)
    }
}

enum TokenArtworkPalette {
    private enum AnalysisError: Error { case bitmapAllocation }
    private struct Bucket {
        var weight = 0.0, red = 0.0, green = 0.0, blue = 0.0
        var color: TokenArtworkColor {
            .init(red: red / weight, green: green / weight, blue: blue / weight)
        }
        mutating func add(_ r: Double, _ g: Double, _ b: Double, weight alpha: Double) {
            weight += alpha; red += r * alpha; green += g * alpha; blue += b * alpha
        }
    }
    private static func hueBucket(_ r: Double, _ g: Double, _ b: Double) -> Int {
        let maximum = max(r, g, b), minimum = min(r, g, b), delta = maximum - minimum
        if maximum < 0.12 || delta / max(maximum, 0.001) < 0.18 {
            return maximum < 0.22 ? 12 : maximum > 0.85 ? 14 : 13
        }
        var hue: Double
        if maximum == r { hue = (g - b) / delta }
        else if maximum == g { hue = 2 + (b - r) / delta }
        else { hue = 4 + (r - g) / delta }
        if hue < 0 { hue += 6 }
        return min(11, Int(hue * 2))
    }

    /// Bounded 48x48 sRGB sampling, performed at decode time on the loader actor,
    /// never in a scrolling view's body. Transparent RGB does not vote; alpha is
    /// unpremultiplied before quantization so soft edges do not bias toward black.
    static func analyze(size: CGSize, draw: (CGContext, CGRect) -> Void) -> TokenArtworkColor {
        let side = 48
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                        | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else {
            OathDiagnostics.record(AnalysisError.bitmapAllocation, component: "artwork", operation: "background_color")
            return .neutral
        }
        context.interpolationQuality = .high
        let scale = CGFloat(side) / max(size.width, size.height)
        let width = size.width * scale, height = size.height * scale
        draw(context, CGRect(x: (CGFloat(side) - width) / 2, y: (CGFloat(side) - height) / 2,
                             width: width, height: height))
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        // Group neighboring shades by hue, rather than splitting a gradient
        // across many RGB buckets and accidentally selecting its white glyph.
        var buckets = [Bucket](repeating: Bucket(), count: 15)
        var shades = [Bucket](repeating: Bucket(), count: 512)
        var total = 0.0
        for i in 0..<(side * side) {
            let x = Double(i % side) + 0.5 - Double(side) / 2
            let y = Double(i / side) + 0.5 - Double(side) / 2
            guard x * x + y * y <= Double(side * side) / 4 else { continue }
            let alpha = Double(pixels[i * 4 + 3]) / 255
            guard alpha >= 0.25 else { continue }
            let r = min(1, Double(pixels[i * 4]) / 255 / alpha)
            let g = min(1, Double(pixels[i * 4 + 1]) / 255 / alpha)
            let b = min(1, Double(pixels[i * 4 + 2]) / 255 / alpha)
            buckets[hueBucket(r, g, b)].add(r, g, b, weight: alpha)
            let shade = min(7, Int(r * 8)) * 64 + min(7, Int(g * 8)) * 8 + min(7, Int(b * 8))
            shades[shade].add(r, g, b, weight: alpha)
            total += alpha
        }
        // Empty/transparent artwork is optional visual content, not a failure.
        guard let index = buckets.indices.max(by: { buckets[$0].weight < buckets[$1].weight }),
              buckets[index].weight > 0 else { return .neutral }
        let dominant = buckets[index]
        var color = dominant.color
        // For a flat badge, prefer its exact dominant shade over antialiased
        // glyph-edge blends. Smooth gradients still use the dominant hue mean.
        if let shade = shades.filter({ $0.weight > 0 && hueBucket($0.color.red, $0.color.green, $0.color.blue) == index })
            .max(by: { $0.weight < $1.weight }), shade.weight >= dominant.weight * 0.5 {
            color = shade.color
        }
        let contrastingWeight = buckets.filter {
            $0.weight > 0 && max(abs($0.color.red - color.red), abs($0.color.green - color.green),
                                abs($0.color.blue - color.blue)) >= 0.18
        }
            .reduce(0) { $0 + $1.weight }
        if total < Double(side * side) * .pi / 4 * 0.98, contrastingWeight < total * 0.02 {
            return color.contrastingShade
        }
        return color
    }
}

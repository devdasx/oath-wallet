import Foundation

/// Untinted surfaces, shared by native UI, the shader and startup artwork.
/// Wallet accents never participate in these colors.
enum OathNeutralColors {
    static let lightCanvas: UInt32 = 0xFFFFFF
    // All page and sheet canvases share pure white in Light appearance.
    // Fields retain their separate gray surface so inputs remain distinguishable.
    static let lightGroupedCanvas: UInt32 = lightCanvas
    static let lightField: UInt32 = 0xF0F0F0
    static let darkCanvas: UInt32 = 0x161616
    static let darkCard: UInt32 = 0x222222
    static let darkField: UInt32 = 0x292929
    static let darkSheet: UInt32 = 0x1C1C1C
    static let darkSheetCard: UInt32 = 0x262626
}

/// Named and custom accents use the same appearance-aware material palette.
public enum OathColorway: String, CaseIterable, Sendable {
    case cobalt, azure, indigo, amethyst, orchid, rose, ruby, copper, champagne, platinum

    public var title: String { rawValue.capitalized }

    var colors: OathSilkColors { .custom(accent) }

    private var accent: UInt32 {
        switch self {
        case .cobalt: 0x244DE0
        case .azure: 0x288CBC
        case .indigo: 0x5140C5
        case .amethyst: 0x8B36C9
        case .orchid: 0xBC39A2
        case .rose: 0xDF438D
        case .ruby: 0xBC2835
        case .copper: 0xCC6B35
        case .champagne: 0xB2964F
        case .platinum: 0x656977
        }
    }
}

/// Eight float4 values, mirrored by OathSilkColors in Metal (128 bytes).
struct OathSilkColors: Equatable, Sendable {
    var lightDeep: SIMD4<Float>
    var lightCrest: SIMD4<Float>
    var darkDeep: SIMD4<Float>
    var darkCrest: SIMD4<Float>
    var lightReflection: SIMD4<Float>
    var darkReflection: SIMD4<Float>
    var lightRest: SIMD4<Float>
    var darkRest: SIMD4<Float>

    /// Preserve the accent's perceptual hue while bounding saturation and
    /// lightness separately for each appearance. Neutral choices remain neutral.
    /// Runs only when the color changes, never in the animation's frame loop.
    static func custom(_ rgb: UInt32) -> Self {
        let accent = OathPerceptualColor(rgb: rgb)
        // Keep very dark and very pale selections distinct without letting a
        // white/yellow accent wash out the material or a black accent lose folds.
        let tone = min(1, max(0, accent.lightness))
        let chroma = min(0.19, accent.chroma)
        func shade(_ lightness: Double, _ saturation: Double) -> SIMD4<Float> {
            accent.shade(lightness: lightness, chroma: chroma * saturation)
        }
        return Self(lightDeep: shade(0.32 + tone * 0.08, 0.80),
                    lightCrest: shade(0.52 + tone * 0.10, 0.90),
                    darkDeep: shade(0.18 + tone * 0.06, 0.55),
                    darkCrest: shade(0.40 + tone * 0.10, 0.85),
                    lightReflection: shade(0.20 + tone * 0.04, 0.35),
                    darkReflection: shade(0.32 + tone * 0.06, 0.50),
                    lightRest: OathPerceptualColor.encodedRGB(OathNeutralColors.lightGroupedCanvas),
                    darkRest: OathPerceptualColor.encodedRGB(OathNeutralColors.darkCanvas))
    }
}

/// Oklab matrices from Björn Ottosson's public-domain reference:
/// https://bottosson.github.io/posts/oklab/
/// All transformations use linear sRGB; the shader receives encoded sRGB.
private struct OathPerceptualColor {
    let lightness: Double
    let chroma: Double
    private let direction: SIMD2<Double>

    init(rgb: UInt32) {
        func linear(_ byte: UInt32) -> Double {
            let value = Double(byte & 255) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let r = linear(rgb >> 16), g = linear(rgb >> 8), b = linear(rgb)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let labB = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        let magnitude = hypot(a, labB)
        chroma = magnitude < 0.0001 ? 0 : magnitude
        direction = chroma == 0 ? .zero : SIMD2(a / chroma, labB / chroma)
    }

    func shade(lightness: Double, chroma: Double) -> SIMD4<Float> {
        func linearRGB(_ chroma: Double) -> SIMD3<Double> {
            let a = direction.x * chroma, b = direction.y * chroma
            let l = lightness + 0.3963377774 * a + 0.2158037573 * b
            let m = lightness - 0.1055613458 * a - 0.0638541728 * b
            let s = lightness - 0.0894841775 * a - 1.2914855480 * b
            let l3 = l * l * l, m3 = m * m * m, s3 = s * s * s
            return SIMD3(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
                         -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
                         -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3)
        }
        func inGamut(_ value: SIMD3<Double>) -> Bool {
            (0..<3).allSatisfy { (0...1).contains(value[$0]) }
        }
        // Reduce chroma instead of clipping channels, retaining the chosen hue.
        // Twelve bounded bisections are used only for out-of-gamut shades.
        var value = linearRGB(chroma)
        if !inGamut(value) {
            var lower = 0.0, upper = chroma
            for _ in 0..<12 {
                let middle = (lower + upper) / 2
                if inGamut(linearRGB(middle)) { lower = middle } else { upper = middle }
            }
            value = linearRGB(lower)
        }
        func encoded(_ value: Double) -> Float {
            let value = min(1, max(0, value))
            return Float(value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055)
        }
        return SIMD4(encoded(value.x), encoded(value.y), encoded(value.z), 1)
    }

    static func encodedRGB(_ hex: UInt32) -> SIMD4<Float> {
        SIMD4(Float((hex >> 16) & 255) / 255, Float((hex >> 8) & 255) / 255, Float(hex & 255) / 255, 1)
    }
}

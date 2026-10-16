import CoreImage
import Foundation

/// Bounded, serial first-frame/Reduce Motion artwork. Decoding and filtering
/// never run on the UI actor; cancelled color-picker requests do no queued work.
actor OathCustomArtworkPoster {
    static let shared = OathCustomArtworkPoster()
    struct Images: Sendable { let silk: CGImage; let reading: CGImage }
    // Shader palette values and the JPEG poster are encoded sRGB. Avoid Core
    // Image's default linear working space changing the palette/readability math.
    private lazy var context = CIContext(options: [
        .useSoftwareRenderer: true, .cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    ])
    private var cache: [String: Images] = [:]
    private var recent: [String] = []
    private let resources: Bundle
    private static let cubeDimension = 32
    private lazy var readingColorCube = Self.makeReadingColorCube()

    init(resources: Bundle = .main) { self.resources = resources }

    func images(rgb: UInt32, dark: Bool) -> Images? {
        guard !Task.isCancelled else { return nil }
        let key = "\(rgb)-\(dark)"
        if let cached = cache[key] { return cached }
        let appearance = dark ? "dark" : "light"
        let palette = OathSilkColors.custom(rgb)
        let deep = dark ? palette.darkDeep : palette.lightDeep
        let crest = dark ? palette.darkCrest : palette.lightCrest
        let source = OathColorway.cobalt.colors
        let sourceDeep = dark ? source.darkDeep.z : source.lightDeep.z
        let sourceCrest = dark ? source.darkCrest.z : source.lightCrest.z
        let range = max(0.01, sourceCrest - sourceDeep)
        let scale = (crest - deep) / range
        let bias = deep - scale * sourceDeep

        func render(reading: Bool) -> CGImage? {
            guard !Task.isCancelled,
                  let url = resources.url(forResource: "OathStartup-cobalt-\(appearance)\(reading ? "-reading" : "")", withExtension: "jpg"),
                  let image = CIImage(contentsOf: url) else { return nil }
            let resized = image.transformed(by: CGAffineTransform(scaleX: 512 / image.extent.width,
                                                                  y: 512 / image.extent.width))
            var result = resized.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: CGFloat(scale.x), w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: CGFloat(scale.y), w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(scale.z), w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: CGFloat(bias.x), y: CGFloat(bias.y), z: CGFloat(bias.z), w: 0)
            ])
            if reading {
                // Match the shader's linear-light readability ceiling without
                // clipping individual channels and shifting the wallet's hue.
                result = result.applyingFilter("CIColorClamp", parameters: [
                    "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
                ]).applyingFilter("CIColorCube", parameters: [
                    "inputCubeDimension": Self.cubeDimension,
                    "inputCubeData": readingColorCube
                ])
            }
            return context.createCGImage(result, from: resized.extent)
        }
        guard let silk = render(reading: false), let reading = render(reading: true), !Task.isCancelled else { return nil }
        let images = Images(silk: silk, reading: reading)
        cache[key] = images
        recent.append(key)
        if recent.count > 4 { cache.removeValue(forKey: recent.removeFirst()) }
        return images
    }

    /// Built once on this worker actor, never during UI updates or animation.
    private static func makeReadingColorCube() -> Data {
        func linear(_ value: Float) -> Float {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        func encoded(_ value: Float) -> Float {
            value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
        }
        var entries: [Float] = []
        entries.reserveCapacity(cubeDimension * cubeDimension * cubeDimension * 4)
        let denominator = Float(cubeDimension - 1)
        for blue in 0..<cubeDimension {
            for green in 0..<cubeDimension {
                for red in 0..<cubeDimension {
                    let rgb = SIMD3(linear(Float(red) / denominator),
                                    linear(Float(green) / denominator),
                                    linear(Float(blue) / denominator))
                    let luminance = rgb.x * 0.2126 + rgb.y * 0.7152 + rgb.z * 0.0722
                    // Leave room for LUT interpolation and 8-bit rounding below
                    // the live shader's 0.10 relative-luminance ceiling.
                    let shade = min(1, 0.098 / max(luminance, 0.001))
                    entries.append(contentsOf: [encoded(rgb.x * shade), encoded(rgb.y * shade),
                                               encoded(rgb.z * shade), 1])
                }
            }
        }
        return entries.withUnsafeBytes { Data($0) }
    }
}

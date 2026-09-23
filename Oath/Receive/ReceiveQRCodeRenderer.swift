import CoreGraphics
import CoreImage
import QRCodeGenerator
import Foundation

final class ReceiveQRCodeMemoryCache: @unchecked Sendable {
    static let shared = ReceiveQRCodeMemoryCache()

    private let storage = NSCache<NSString, CGImage>()

    private init() {
        storage.countLimit = 24
        storage.totalCostLimit = 32 * 1_024 * 1_024
    }

    func image(for payload: String) -> CGImage? {
        storage.object(forKey: payload as NSString)
    }

    func insert(_ image: CGImage, for payload: String) {
        let cost = image.bytesPerRow * image.height
        storage.setObject(
            image,
            forKey: payload as NSString,
            cost: cost
        )
    }
}

actor ReceiveQRCodeRenderer {
    static let shared = ReceiveQRCodeRenderer()

    private let cache = ReceiveQRCodeMemoryCache.shared
    private lazy var context = CIContext(options: [
        .useSoftwareRenderer: true,
        .cacheIntermediates: false
    ])
    private static let roundedModuleScale = 16

    /// Encodes and rasterizes on this actor. Apple's iOS 26 generator supplies
    /// rounded markers and data dots; older systems keep the CPU module encoder.
    /// Both paths return an 8-bit mask with a four-module quiet zone, so shared
    /// appearance, reveal and export views use exactly the same scannable image.
    func image(for payload: String, cacheResult: Bool = true) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        if cacheResult, let image = cache.image(for: payload) {
            return image
        }
        // Version 40-M accepts at most 2,331 byte-mode bytes. Bound input before
        // allocating the encoder's data structures, including noncached secrets.
        guard payload.utf8.count <= 2_331 else { return nil }
        let image = roundedImage(for: payload) ?? Self.legacyImage(for: payload)
        guard !Task.isCancelled, let image else { return nil }
        if cacheResult { cache.insert(image, for: payload) }
        return image
    }

    private func roundedImage(for payload: String) -> CGImage? {
        guard let output = WalletPlatformQRCodeGenerator.roundedImage(
            message: Data(payload.utf8), moduleScale: Self.roundedModuleScale
        ) else { return nil }
        // Core Image includes one quiet module. Add three more at the native
        // raster scale, before tinting, rather than relying on screen padding.
        let border = CGFloat(3 * Self.roundedModuleScale)
        let bounds = output.extent.insetBy(dx: -border, dy: -border)
        let background = CIImage(color: .white).cropped(to: bounds)
        let padded = output.composited(over: background)
        guard !Task.isCancelled else { return nil }
        // Core Image's high-resolution raster supports interpolation for
        // smooth curves; legacy one-pixel modules remain nearest-neighbor.
        // Finish rendering here, before handing the bitmap to the UI.
        return context.createCGImage(
            padded, from: bounds, format: .L8,
            colorSpace: CGColorSpaceCreateDeviceGray(), deferred: false
        )
    }

    /// Compatibility path, also used if Core Image cannot produce a bitmap.
    static func legacyImage(for payload: String) -> CGImage? {
        guard !Task.isCancelled, payload.utf8.count <= 2_331 else { return nil }
        do {
            let bytes = Array(payload.utf8)
            var segments: [Segment] = []
            if bytes.contains(where: { $0 >= 128 }) {
                segments.append(try Segment.makeECI(designator: 26)) // UTF-8
            }
            segments.append(try Segment.makeBytes(data: bytes))
            let code = try QRCode.encode(
                segments: segments, correctionLevel: .medium, boostEcl: false
            )
            guard !Task.isCancelled else { return nil }
            let border = 4
            let dimension = code.size + border * 2
            var pixels = [UInt8](repeating: 255, count: dimension * dimension)
            for y in 0..<code.size {
                for x in 0..<code.size where code[x, y] {
                    pixels[(y + border) * dimension + x + border] = 0
                }
            }
            guard let provider = CGDataProvider(data: Data(pixels) as CFData),
                  let image = CGImage(
                    width: dimension, height: dimension,
                    bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: dimension,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false,
                    intent: .defaultIntent
                  ) else { return nil }
            guard !Task.isCancelled else { return nil }
            return image
        } catch {
            return nil
        }
    }
}

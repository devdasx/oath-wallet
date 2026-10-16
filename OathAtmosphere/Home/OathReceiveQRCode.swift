import CoreImage.CIFilterBuiltins
import Foundation

/// The payload is always the wallet address, never an example token contract.
/// Render once per address, at an integer module scale, with an opaque white
/// quiet zone that stays white in both appearances.
enum OathReceiveQRCode {
    // Shared with the on-screen badge and host decoding checks. Keep the logo
    // inside this small protected center; never cover the finder/quiet zones.
    static let displaySide: CGFloat = 320
    static let badgeFraction: CGFloat = 0.18
    static let logoFraction: CGFloat = 0.12

    static func image(for address: String) -> CGImage? {
        // Core Image is Apple's native QR encoder. High error correction is
        // required for the center branding; private-key QR output stays intact.
        guard let encoded = OathQRCode.image(payload: address, correctionLevel: "H"),
              let context = CGContext(data: nil, width: encoded.width, height: encoded.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: encoded.width, height: encoded.height)
        context.interpolationQuality = .none
        // Draw Apple's QR image directly; do not redraw or restyle its modules.
        context.draw(encoded, in: bounds)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        let badge = centeredRect(in: bounds, fraction: badgeFraction)
        context.fillEllipse(in: badge)
        return context.makeImage()
    }

    static func centeredRect(in bounds: CGRect, fraction: CGFloat) -> CGRect {
        let side = min(bounds.width, bounds.height) * fraction
        return CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }
}

/// Sensitive payloads stay in memory; no image file, URL or shared cache.
enum OathPrivateKeyQRCode {
    static func image(for key: String) -> CGImage? { OathQRCode.image(payload: key) }
}

private enum OathQRCode {
    static func image(payload: String, correctionLevel: String = "M") -> CGImage? {
        guard !payload.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = correctionLevel
        guard let output = filter.outputImage else { return nil }
        let quietZone = output.extent.insetBy(dx: -4, dy: -4)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: quietZone)
        let image = output.composited(over: white).transformed(by: .init(scaleX: 8, y: 8))
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(image, from: image.extent)
    }
}

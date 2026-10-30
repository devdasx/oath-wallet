import CoreImage.CIFilterBuiltins
import Foundation
#if canImport(OathDatabase)
import OathDatabase

/// The payload is always the wallet address, never an example token contract.
/// Render once per address, at an integer module scale, with an opaque white
/// quiet zone that stays white in both appearances.
enum OathReceiveQRCode {
    // Shared with the on-screen badge and host decoding checks. Keep the logo
    // inside this small protected center; never cover the finder/quiet zones.
    static let displaySide: CGFloat = 320
    static let badgeFraction = ReceiveQRImage.badgeFraction
    static let logoFraction = ReceiveQRImage.logoFraction

    static func image(for address: String) -> CGImage? {
        ReceiveQRImage.image(for: address)
    }

    static func centeredRect(in bounds: CGRect, fraction: CGFloat) -> CGRect {
        let side = min(bounds.width, bounds.height) * fraction
        return CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }
}
#endif

/// Sensitive payloads stay in memory; no image file, URL or shared cache.
enum OathPrivateKeyQRCode {
    static func image(for key: String) -> CGImage? { OathQRCode.image(payload: key) }
}

private enum OathQRCode {
    static func image(payload: String, correctionLevel: String = "M",
                      context: CIContext = CIContext(options: [.cacheIntermediates: false])) -> CGImage? {
        guard !payload.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = correctionLevel
        guard let output = filter.outputImage else { return nil }
        let quietZone = output.extent.insetBy(dx: -4, dy: -4)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: quietZone)
        let image = output.composited(over: white).transformed(by: .init(scaleX: 8, y: 8))
        return context.createCGImage(image, from: image.extent)
    }
}

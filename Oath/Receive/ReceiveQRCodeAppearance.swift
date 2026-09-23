import SwiftUI
import UIKit

/// Colors the cached module bitmap without re-encoding its payload or quiet zone.
@MainActor
enum ReceiveQRCodeAppearance {
    static func image(_ source: CGImage, colorScheme: ColorScheme) -> CGImage {
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        let surface = UIColor(WalletTheme.qrCodeSurface).resolvedColor(with: traits).cgColor
        let ink = UIColor(WalletTheme.qrCodeInk).resolvedColor(with: traits).cgColor
        // Both encoders emit 8-bit grayscale: dark modules are opaque, white
        // quiet-zone pixels are transparent, and Apple's antialiased curves
        // retain their coverage when the light/dark palette changes.
        guard let provider = source.dataProvider,
              let mask = CGImage(maskWidth: source.width, height: source.height,
                                 bitsPerComponent: source.bitsPerComponent,
                                 bitsPerPixel: source.bitsPerPixel,
                                 bytesPerRow: source.bytesPerRow, provider: provider,
                                 decode: nil, shouldInterpolate: false),
              let context = CGContext(data: nil, width: source.width, height: source.height,
                                      bitsPerComponent: 8, bytesPerRow: source.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return source }
        context.interpolationQuality = .none
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        context.setFillColor(surface)
        context.fill(bounds)
        context.clip(to: bounds, mask: mask)
        context.setFillColor(ink)
        context.fill(bounds)
        guard let tinted = context.makeImage(),
              let tintedProvider = tinted.dataProvider,
              let colorSpace = tinted.colorSpace else { return source }
        // Preserve the renderer's scaling policy through palette changes:
        // smooth the rounded raster, keep legacy single-pixel modules sharp.
        return CGImage(
            width: tinted.width, height: tinted.height,
            bitsPerComponent: tinted.bitsPerComponent, bitsPerPixel: tinted.bitsPerPixel,
            bytesPerRow: tinted.bytesPerRow, space: colorSpace,
            bitmapInfo: tinted.bitmapInfo, provider: tintedProvider, decode: nil,
            shouldInterpolate: source.shouldInterpolate, intent: .defaultIntent
        ) ?? tinted
    }
}

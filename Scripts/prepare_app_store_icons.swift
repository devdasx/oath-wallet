// Installs the supplied Oath icons without resizing or altering the artwork.
// Removes the unused alpha channel required by App Store icon validation.
// Run `swift Scripts/prepare_app_store_icons.swift [--check]` from the repo root.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct IconExportError: Error, CustomStringConvertible {
    let description: String
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let checkOnly = CommandLine.arguments.contains("--check")

func opaquePNG(_ data: Data, appearance: String) throws -> Data {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width == 1024, image.height == 1024,
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        throw IconExportError(description: "The supplied Oath icon must be 1024 pixels: \(appearance)")
    }
    let rowBytes = image.width * 4
    guard let context = CGContext(
        data: nil, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: rowBytes, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw IconExportError(description: "Cannot read icon pixels: \(appearance)")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self),
          stride(from: 3, to: rowBytes * image.height, by: 4).allSatisfy({ pixels[$0] == 255 }),
          let rendered = context.makeImage(),
          let opaque = CGImage(
              width: rendered.width, height: rendered.height,
              bitsPerComponent: rendered.bitsPerComponent, bitsPerPixel: rendered.bitsPerPixel,
              bytesPerRow: rendered.bytesPerRow, space: colorSpace,
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
              provider: rendered.dataProvider!, decode: nil, shouldInterpolate: false,
              intent: .defaultIntent
          ) else {
        throw IconExportError(description: "The supplied icon contains transparent pixels: \(appearance)")
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
        throw IconExportError(description: "Cannot encode icon: \(appearance)")
    }
    CGImageDestinationAddImage(destination, opaque, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw IconExportError(description: "Cannot finish icon: \(appearance)")
    }
    return output as Data
}

do {
    for appearance in ["light", "dark", "tinted"] {
        let original = root.appendingPathComponent(
            "Branding/Oath Brand Kit/01 App Icon/oath-app-icon-\(appearance)-1024.png"
        )
        let canonical = try opaquePNG(Data(contentsOf: original), appearance: appearance)
        guard
              let source = CGImageSourceCreateWithData(canonical as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == 1024, image.height == 1024,
              [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) else {
            throw IconExportError(description: "Oath app icon must be opaque and 1024 pixels: \(appearance)")
        }
        let destination = root.appendingPathComponent(
            "EVMWallet/Assets.xcassets/AppIcon.appiconset/icon-\(appearance).png"
        )
        if !checkOnly { try canonical.write(to: destination, options: .atomic) }
        guard try Data(contentsOf: destination) == canonical else {
            throw IconExportError(description: "Icon differs from the current Oath brand kit: \(appearance)")
        }
        print("Verified official opaque 1024-pixel Oath icon: \(appearance)")
    }
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}

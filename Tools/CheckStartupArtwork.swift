import Foundation
import ImageIO

@main
struct CheckStartupArtwork {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let bundle = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1])
            : root.appendingPathComponent(".build/PasscodeDerivedData/Build/Products/Release-iphoneos/Oath Wallet.app")
        let source = root.appendingPathComponent("OathApp/Resources/Startup")
        let names = OathColorway.allCases.flatMap { color in
            ["light", "dark"].flatMap { appearance in
                ["", "-reading"].map { "OathStartup-\(color.rawValue)-\(appearance)\($0).jpg" }
            }
        } + ["OathStartup-logo-light.png", "OathStartup-logo-dark.png"]
        var totalBytes = 0
        for name in names {
            try autoreleasepool {
                let data = try Data(contentsOf: source.appendingPathComponent(name))
                let bundled = try Data(contentsOf: bundle.appendingPathComponent(name))
                let imageSource = CGImageSourceCreateWithData(data as CFData, nil)!
                let image = CGImageSourceCreateImageAtIndex(imageSource, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)!
                let bundledSource = CGImageSourceCreateWithData(bundled as CFData, nil)!
                let bundledImage = CGImageSourceCreateImageAtIndex(bundledSource, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)!
                let logo = name.contains("logo")
                precondition(image.width == (logo ? 4096 : 1024) && image.height == (logo ? 3072 : 2560))
                precondition(image.width == bundledImage.width && image.height == bundledImage.height)
                if logo {
                    // Xcode optimizes PNGs into CgBI. Compare decoded pixels,
                    // allowing one channel step for alpha premultiplication.
                    let original = pixels(image), compiled = pixels(bundledImage)
                    var maximumDifference = 0
                    for i in original.indices { maximumDifference = max(maximumDifference, abs(Int(original[i]) - Int(compiled[i]))) }
                    precondition(maximumDifference <= 1, "Compiled logo changed: \(maximumDifference)/255")
                } else {
                    precondition(data == bundled, "Missing or stale bundled image: \(name)")
                }
                if logo { precondition(image.alphaInfo != .none && image.alphaInfo != .noneSkipLast && image.alphaInfo != .noneSkipFirst) }
                totalBytes += data.count
            }
        }
        precondition(MemoryLayout<AtmosphereUniforms>.stride == 112)
        // Initial empty proposals, portrait phones, narrow/tall layouts, and
        // measured RTL spread geometry all need finite first-frame coordinates.
        for size in [CGSize.zero, CGSize(width: 320, height: 568), CGSize(width: 440, height: 956),
                     CGSize(width: 280, height: 1100), CGSize(width: 900, height: 700)] {
            for rtl in [false, true] {
                let layout = OathOnboardingLayout(size: size, actionHeight: 290, introductionHeight: 210, rightToLeft: rtl)
                let placement = OathArtworkPlacement(
                    logo: CGRect(origin: layout.introduction.origin, size: layout.logoSize),
                    logoClip: layout.introduction,
                    copy: CGRect(x: layout.introduction.minX, y: layout.introduction.midY, width: layout.introduction.width, height: 180),
                    actions: layout.actions, spreadDivider: layout.spreadDivider
                )
                for measured in [Optional<OathArtworkPlacement>.none, placement] {
                    let frame = OathArtworkFrame(size: size, safeTop: 62, placement: measured)
                    let u = frame.uniforms(pixelSize: size, time: 0, appearance: 0, interaction: .zero)
                    for vector in [u.logoRect, u.logoClip, u.copyRect, u.fadeLayout, u.panelLayout] {
                        precondition((0..<4).allSatisfy { vector[$0].isFinite })
                    }
                    if let divider = layout.spreadDivider, measured != nil {
                        precondition(frame.divider == divider && frame.actionsOnRight != rtl)
                    }
                }
            }
        }
        print("42 bundled images decoded and matched source (PNG pixels, JPEG bytes); 4K logo alpha retained; \(totalBytes) bytes total.")
        print("20 first-frame layouts: finite uniforms; measured RTL spread sides preserved; uniform stride 112 bytes.")
    }

    private static func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}

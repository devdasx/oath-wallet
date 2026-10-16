import Foundation
import AppKit
import MetalKit

/// Real shader output on the Mac GPU; this is not an iOS runtime/visual test.
@main struct CheckArtworkMotion {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal is required for the host artwork-motion check")
        }
        let source = try String(contentsOf: root.appendingPathComponent("Shaders/OathSilk.metal"), encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        let logo = try OathLogoTexture.load(url: root.appendingPathComponent("OathApp/Resources/OathGlassNormals.png"),
                                           device: device, queue: queue, library: library)
        let pipeline = MTLRenderPipelineDescriptor()
        pipeline.vertexFunction = library.makeFunction(name: "oathVertex")
        pipeline.fragmentFunction = library.makeFunction(name: "oathFragment")
        pipeline.colorAttachments[0].pixelFormat = .rgba8Unorm
        let state = try device.makeRenderPipelineState(descriptor: pipeline)
        let width = 320, height = 640
        let size = CGSize(width: width, height: height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        let target = device.makeTexture(descriptor: descriptor)!
        precondition(MemoryLayout<AtmosphereUniforms>.stride == 112 && MemoryLayout<OathSilkColors>.stride == 128)

        func render(palette: OathSilkColors, dark: Bool, wallet: Bool, time: Float) -> [UInt8] {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let command = queue.makeCommandBuffer()!
            let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
            encoder.setRenderPipelineState(state)
            encoder.setFragmentTexture(logo, index: 0)
            let frame = OathArtworkFrame(size: size, safeTop: 62, placement: wallet ? .walletBackdrop(size: size) : nil)
            var uniforms = frame.uniforms(pixelSize: size, time: time, appearance: dark ? 1 : 0, interaction: .zero)
            var palette = palette
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<AtmosphereUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&palette, length: MemoryLayout<OathSilkColors>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted() // Offline host check only.
            precondition(command.status == .completed, "Host GPU command failed")
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            precondition(stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 })
            return bytes
        }

        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminanceChannel = (0...255).map { linear(Double($0) / 255) }
        let captionChannel = (0...255).map { linear(0.76 + 0.24 * Double($0) / 255) }
        func luminance(_ bytes: [UInt8], _ index: Int, _ channels: [Double]) -> Double {
            channels[Int(bytes[index])] * 0.2126 + channels[Int(bytes[index + 1])] * 0.7152
                + channels[Int(bytes[index + 2])] * 0.0722
        }
        let colors: [UInt32?] = [nil, 0x8B36C9, 0x288CBC, 0x126BB5, 0x12989C, 0x209750,
                                 0xDF438D, 0xEE741B, 0xBC2835, 0x656977, 0x000000, 0xFFFFFF,
                                 0xFFFF00, 0x00FF00]
        var cases = 0
        var peakReadingLuminance = 0.0, minimumCaptionContrast = Double.infinity
        for dark in [false, true] {
            for wallet in [false, true] {
                for color in colors {
                    try autoreleasepool {
                        let palette = color.map(OathSilkColors.custom) ?? OathColorway.cobalt.colors
                        let first = render(palette: palette, dark: dark, wallet: wallet, time: 0)
                        let next = render(palette: palette, dark: dark, wallet: wallet, time: 4)
                        // Only inspect the artwork region, excluding the neutral
                        // welcome action panel. Detect actual spatial movement
                        // for each fixed color, not just a palette replacement.
                        let channels = width * (height / 3) * 4
                        let changed = zip(first.prefix(channels), next.prefix(channels)).filter { abs(Int($0) - Int($1)) > 2 }.count
                        guard changed > channels / 100 else {
                            throw CheckError.noMotion(color: color, dark: dark, wallet: wallet)
                        }
                        for frame in [first, next] {
                            if wallet {
                                // Home/Customize white copy sits above the bottom
                                // fade. Test actual encoded pixels, not palette math.
                                for pixel in stride(from: 0, to: width * (height - 64) * 4, by: 4) {
                                    let background = luminance(frame, pixel, luminanceChannel)
                                    let caption = luminance(frame, pixel, captionChannel)
                                    peakReadingLuminance = max(peakReadingLuminance, background)
                                    minimumCaptionContrast = min(minimumCaptionContrast, (caption + 0.05) / (background + 0.05))
                                }
                                if color == 0xFFFFFF || color == 0x000000 {
                                    for pixel in stride(from: 0, to: channels, by: 4) {
                                        precondition(abs(Int(frame[pixel]) - Int(frame[pixel + 1])) <= 1)
                                        precondition(abs(Int(frame[pixel]) - Int(frame[pixel + 2])) <= 1)
                                    }
                                }
                            } else {
                                // Welcome's resting page has no wallet-color cast.
                                let rest = dark ? OathNeutralColors.darkCanvas : OathNeutralColors.lightGroupedCanvas
                                let expected = Int(rest & 255)
                                for pixel in stride(from: width * (height - 32) * 4, to: frame.count, by: 4) {
                                    precondition((0..<3).allSatisfy { abs(Int(frame[pixel + $0]) - expected) <= 1 })
                                }
                            }
                        }
                        cases += 1
                    }
                }
            }
        }
        precondition(peakReadingLuminance <= 0.104, "Reading region exceeds its luminance ceiling")
        precondition(minimumCaptionContrast >= 4.5, "Secondary white text loses contrast")
        print("PASS: \(cases * 2) opaque Mac GPU frames; spatial motion in all \(cases) color/appearance/layout cases, including black, white and yellow")
        print(String(format: "Reading-region peak luminance %.4f; minimum 76%% white-caption contrast %.2f:1; neutral resting surfaces verified", peakReadingLuminance, minimumCaptionContrast))

        // Optional comparison of real shader pixels, not a simulator screenshot.
        if let path = CommandLine.arguments.dropFirst().first {
            let swatches: [UInt32] = [0x244DE0, 0xDF438D, 0xFFFF00, 0x656977, 0x000000, 0xFFFFFF]
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * swatches.count,
                pixelsHigh: height * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied,
                bytesPerRow: width * swatches.count * 4, bitsPerPixel: 32)!
            for (row, dark) in [false, true].enumerated() {
                for (column, color) in swatches.enumerated() {
                    let frame = render(palette: .custom(color), dark: dark, wallet: true, time: 4)
                    frame.withUnsafeBytes { source in
                        for y in 0..<height {
                            bitmap.bitmapData!.advanced(by: (row * height + y) * bitmap.bytesPerRow + column * width * 4)
                                .update(from: source.baseAddress!.advanced(by: y * width * 4).assumingMemoryBound(to: UInt8.self), count: width * 4)
                        }
                    }
                }
            }
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        }
    }

    private enum CheckError: Error { case noMotion(color: UInt32?, dark: Bool, wallet: Bool) }
}

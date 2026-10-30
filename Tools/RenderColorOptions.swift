import AppKit
import Foundation
import MetalKit

private struct FrameUniforms {
    var resolution: SIMD2<Float>
    var timeAndAppearance: SIMD2<Float>
    var interaction = SIMD2<Float>.zero
    var logoLayout = SIMD2<Float>.zero
    var logoRect = SIMD4<Float>.zero
    var fadeLayout = SIMD4<Float>.zero
    var copyRect = SIMD4<Float>.zero
    var logoClip = SIMD4<Float>.zero
    var panelLayout = SIMD4<Float>.zero
}

@main
struct RenderColorOptions {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = root.appendingPathComponent("Design/Color-Options")
        let screens = output.appendingPathComponent("Screens")
        try FileManager.default.createDirectory(at: screens, withIntermediateDirectories: true)
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal unavailable")
        }
        let source = try String(contentsOf: root.appendingPathComponent("Shaders/OathSilk.metal"), encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        let logo = try OathLogoTexture.load(
            url: root.appendingPathComponent("OathApp/Resources/OathGlassNormals.png"),
            device: device, queue: queue, library: library
        )
        precondition(logo.width == 4096 && logo.height == 3072 && logo.mipmapLevelCount > 1)
        precondition(MemoryLayout<FrameUniforms>.stride == 112 && MemoryLayout<OathSilkColors>.stride == 128)
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "oathVertex")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "oathFragment")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        let width = 1320, height = 2868
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        textureDescriptor.usage = .renderTarget
        textureDescriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: textureDescriptor)!
        var allImages: [[NSImage]] = []
        var manifest: [[String: Any]] = []

        for (index, colorway) in OathColorway.allCases.enumerated() {
            let name = String(format: "%02d-%@", index + 1, colorway.rawValue)
            var colors = colorway.colors
            var images: [NSImage] = []
            for dark in [false, true] {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = texture
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                let command = queue.makeCommandBuffer()!
                let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(logo, index: 0)
                var frame = FrameUniforms(
                    resolution: SIMD2(Float(width), Float(height)),
                    timeAndAppearance: SIMD2(0, dark ? 1 : 0)
                )
                encoder.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 0)
                encoder.setFragmentBytes(&colors, length: MemoryLayout<OathSilkColors>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
                command.commit()
                command.waitUntilCompleted()
                precondition(command.status == .completed, "Rendering failed")
                var pixels = [UInt8](repeating: 0, count: width * height * 4)
                texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                precondition(stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 255 })
                let resting = dark ? colors.darkRest : colors.lightRest
                for channel in 0..<3 {
                    let expected = Int((resting[channel] * 255).rounded())
                    for y in stride(from: height * 3 / 4, to: height, by: 12) {
                        for x in stride(from: 0, to: width, by: 12) {
                            precondition(abs(Int(pixels[(y * width + x) * 4 + channel]) - expected) <= 1,
                                         "The lower area must remain calm in every colorway")
                        }
                    }
                }
                let bitmap = makeBitmap(width: width, height: height)
                pixels.withUnsafeBytes {
                    bitmap.bitmapData!.update(from: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), count: pixels.count)
                }
                let data = bitmap.representation(using: .png, properties: [:])!
                let mode = dark ? "dark" : "light"
                try data.write(to: screens.appendingPathComponent("\(name)-\(mode).png"))
                images.append(NSImage(cgImage: bitmap.cgImage!, size: NSSize(width: width, height: height)))
            }
            let board = makeBitmap(width: 2832, height: 3092)
            drawOn(board) {
                fillBackground(board)
                drawText(String(format: "%02d", index + 1) + "  " + colorway.title,
                         x: 64, top: 34, size: 42, height: board.pixelsHigh, weight: .semibold)
                drawText("LIGHT", x: 64, top: 108, size: 23, height: board.pixelsHigh, secondary: true)
                drawText("DARK", x: 1448, top: 108, size: 23, height: board.pixelsHigh, secondary: true)
                drawImage(images[0], x: 64, top: 160, width: 1320, height: 2868, canvasHeight: board.pixelsHigh)
                drawImage(images[1], x: 1448, top: 160, width: 1320, height: 2868, canvasHeight: board.pixelsHigh)
            }
            try board.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name).png"))
            allImages.append(images)
            manifest.append([
                "number": index + 1, "name": colorway.title, "colorway": colorway.rawValue,
                "comparison": "\(name).png", "light": "Screens/\(name)-light.png", "dark": "Screens/\(name)-dark.png",
                "screen_dimensions": [width, height], "animation_time_seconds": 0,
                "render_source": "Actual app Metal shader, palette, and 4K logo loader on the Mac GPU"
            ])
            print("\(index + 1)/10 • \(colorway.title) • light + dark • full-resolution PNGs saved")
        }

        let contact = makeBitmap(width: 2180, height: 1184)
        drawOn(contact) {
            fillBackground(contact)
            drawText("Oath · Color directions", x: 64, top: 38, size: 38, height: contact.pixelsHigh, weight: .semibold)
            drawText("10 palettes · Light on the left, dark on the right · Same animation frame",
                     x: 64, top: 94, size: 21, height: contact.pixelsHigh, secondary: true)
            for (index, colorway) in OathColorway.allCases.enumerated() {
                let x = 64 + (index % 5) * 416
                let top = 166 + (index / 5) * 504
                drawText(String(format: "%02d", index + 1) + "  " + colorway.title,
                         x: x, top: top, size: 24, height: contact.pixelsHigh, weight: .medium)
                drawImage(allImages[index][0], x: x, top: top + 44, width: 184, height: 400, canvasHeight: contact.pixelsHigh)
                drawImage(allImages[index][1], x: x + 204, top: top + 44, width: 184, height: 400, canvasHeight: contact.pixelsHigh)
            }
        }
        try contact.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("00-color-overview.png"))
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("manifest.json"))
        print("Saved overview and 10 color comparisons to \(output.path)")
    }

    private static func makeBitmap(width: Int, height: Int) -> NSBitmapImageRep {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                         bytesPerRow: width * 4, bitsPerPixel: 32)!
    }

    private static func drawOn(_ bitmap: NSBitmapImageRep, draw: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func fillBackground(_ bitmap: NSBitmapImageRep) {
        NSColor(srgbRed: 0.06, green: 0.065, blue: 0.08, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh).fill()
    }

    private static func drawText(_ string: String, x: Int, top: Int, size: CGFloat, height: Int,
                                 weight: NSFont.Weight = .regular, secondary: Bool = false) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: secondary ? NSColor(white: 0.64, alpha: 1) : NSColor(white: 0.94, alpha: 1)
        ]
        let text = string as NSString
        text.draw(at: NSPoint(x: CGFloat(x), y: CGFloat(height - top) - text.size(withAttributes: attributes).height), withAttributes: attributes)
    }

    private static func drawImage(_ image: NSImage, x: Int, top: Int, width: Int, height: Int, canvasHeight: Int) {
        image.draw(in: NSRect(x: x, y: canvasHeight - top - height, width: width, height: height),
                   from: .zero, operation: .sourceOver, fraction: 1)
    }
}

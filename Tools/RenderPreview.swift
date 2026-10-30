import Foundation
import MetalKit
import AppKit

struct Uniforms {
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
struct OathRenderPreview {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fatalError("Metal unavailable") }
        let source = try String(contentsOf: root.appendingPathComponent("Shaders/OathSilk.metal"), encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        let logoPath = CommandLine.arguments.contains("--bundled-logo")
            ? "DerivedData/Build/Products/Release-iphoneos/Oath Wallet.app/OathGlassNormals.png"
            : "OathApp/Resources/OathGlassNormals.png"
        let logoNormals = try OathLogoTexture.load(url: root.appendingPathComponent(logoPath), device: device, queue: queue, library: library)
        precondition(logoNormals.width == 4096 && logoNormals.height == 3072, "The bundled logo must be the 4K export")
        precondition(logoNormals.mipmapLevelCount > 1, "Scaled logo edges require coverage-filtered mipmaps")

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "oathVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "oathFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        var silkColors = OathColorway.cobalt.colors
        let icon = CommandLine.arguments.contains("--icon")
        let width = icon ? 4096 : 1320, height = icon ? 3072 : 2868
        let texDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        texDescriptor.usage = [.renderTarget]
        texDescriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: texDescriptor)!
        var prior: [UInt8] = []
        let frames: [(String, Float, Float)] = icon ? [("icon", 1, 0)] : [("dark", 1, 0), ("light", 0, 0), ("dark-08s", 1, 8), ("light-08s", 0, 8)]
        for (name, dark, time) in frames {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let command = queue.makeCommandBuffer()!
            let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(logoNormals, index: 0)
            var uniforms = Uniforms(resolution: SIMD2(Float(width), Float(height)), timeAndAppearance: SIMD2(time, dark))
            precondition(MemoryLayout<Uniforms>.stride == 112)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&silkColors, length: MemoryLayout<OathSilkColors>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else { fatalError("GPU failed: \(String(describing: command.error))") }
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            precondition(stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 }, "All pixels must be opaque")
            if !icon {
                // The artwork must reach both screen edges, not just occupy a
                // floating object in the center of an otherwise empty canvas.
                for edgeStart in [0, width * 9 / 10] {
                    var minimum = 255, maximum = 0
                    for y in stride(from: 0, to: height / 2, by: 8) {
                        for x in stride(from: edgeStart, to: edgeStart + width / 10, by: 8) {
                            let blue = Int(bytes[(y * width + x) * 4 + 2])
                            minimum = min(minimum, blue)
                            maximum = max(maximum, blue)
                        }
                    }
                    precondition(maximum - minimum > 40, "Animated material must fill both sides of the upper screen")
                }
                for band in 0..<2 {
                    let firstRow = band * height / 4
                    let lastRow = (band + 1) * height / 4
                    var minimum = 255, maximum = 0
                    for y in stride(from: firstRow, to: lastRow, by: 4) {
                        for x in stride(from: 0, to: width, by: 4) {
                            let green = Int(bytes[(y * width + x) * 4 + 1])
                            minimum = min(minimum, green)
                            maximum = max(maximum, green)
                        }
                    }
                    precondition(maximum - minimum > 24, "Quarter \(band) must contain visible upper artwork")
                }
            }
            if !icon {
                // The lower quarter is intentionally quiet for later onboarding content.
                let start = height * 3 / 4 * width * 4
                let bottomGreen = stride(from: start + 1, to: bytes.count, by: 4).map { bytes[$0] }
                precondition(Int(bottomGreen.max()!) - Int(bottomGreen.min()!) <= 2, "Lower area must be visually calm")

                // Compare the transparent top margin with the same background and
                // the logo placed offscreen. This catches mip seams at the bounds.
                let baselineCommand = queue.makeCommandBuffer()!
                let baselineEncoder = baselineCommand.makeRenderCommandEncoder(descriptor: pass)!
                baselineEncoder.setRenderPipelineState(pipeline)
                baselineEncoder.setFragmentTexture(logoNormals, index: 0)
                var baselineUniforms = uniforms
                baselineUniforms.logoLayout = SIMD2(2.0, 0.66)
                baselineEncoder.setFragmentBytes(&baselineUniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                baselineEncoder.setFragmentBytes(&silkColors, length: MemoryLayout<OathSilkColors>.stride, index: 1)
                baselineEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                baselineEncoder.endEncoding()
                baselineCommand.commit()
                baselineCommand.waitUntilCompleted()
                precondition(baselineCommand.status == .completed)
                let marginY = Int(0.214 * Float(height) - 0.66 * 0.75 * Float(width) / 2)
                let marginHeight = 12
                var baseline = [UInt8](repeating: 0, count: width * marginHeight * 4)
                texture.getBytes(&baseline, bytesPerRow: width * 4, from: MTLRegionMake2D(0, marginY, width, marginHeight), mipmapLevel: 0)
                let marginStart = marginY * width * 4
                let difference = zip(bytes[marginStart..<(marginStart + baseline.count)], baseline)
                    .map { abs(Int($0.0) - Int($0.1)) }.max()!
                precondition(difference <= 1, "Transparent logo margin must not leave a visible texture-boundary seam")
                print("Transparent logo margin matches background • max difference \(difference)/255")
            }
            if name == "dark" { prior = bytes }
            if name == "dark-08s" {
                let changed = zip(prior, bytes).filter { abs(Int($0.0) - Int($0.1)) > 4 }.count
                precondition(changed > bytes.count / 20, "Animation must change the composition")
                for band in 0..<2 {
                    let start = band * height / 4 * width * 4
                    let end = (band + 1) * height / 4 * width * 4
                    let bandChanges = zip(prior[start..<end], bytes[start..<end]).filter { abs(Int($0.0) - Int($0.1)) > 4 }.count
                    precondition(bandChanges > (end-start)/20, "Animation must reach the upper artwork")
                }
                print("Upper artwork and motion checks passed")
                print("Animation changes \(changed) channels by more than 4/255")
            }
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
            bytes.withUnsafeBytes { bitmap.bitmapData!.update(from: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), count: bytes.count) }
            let data = bitmap.representation(using: .png, properties: [:])!
            try data.write(to: root.appendingPathComponent("Validation/\(name).png"))
            print("Rendered \(name) • \(width) × \(height) • GPU complete • opaque")
        }

        if CommandLine.arguments.contains("--profile") {
            var samples: [Double] = []
            for frame in 0..<90 {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = texture
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                let command = queue.makeCommandBuffer()!
                let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(logoNormals, index: 0)
                var uniforms = Uniforms(resolution: SIMD2(Float(width), Float(height)), timeAndAppearance: SIMD2(Float(frame)/60, 1))
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentBytes(&silkColors, length: MemoryLayout<OathSilkColors>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
                command.commit()
                command.waitUntilCompleted()
                precondition(command.status == .completed)
                if frame >= 10 { samples.append((command.gpuEndTime-command.gpuStartTime)*1000) }
            }
            samples.sort()
            print(String(format: "Mac GPU only • 1320 × 2868 • 80 measured frames • median %.3f ms • p95 %.3f ms", samples[samples.count/2], samples[Int(Double(samples.count)*0.95)]))
        }
    }
}

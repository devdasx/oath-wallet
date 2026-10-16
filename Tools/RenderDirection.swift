import AppKit
import AVFoundation
import Foundation
import MetalKit

private struct DirectionUniforms {
    var resolution: SIMD2<Float>
    var timeAndAppearance: SIMD2<Float>
    var interaction = SIMD2<Float>.zero
    var logoLayout = SIMD2<Float>.zero
}

private final class DirectionGPU {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    let logo: MTLTexture
    let stillPipeline: MTLRenderPipelineState
    let moviePipeline: MTLRenderPipelineState
    var lastGPUMilliseconds: Double = 0

    init(root: URL, folder: URL) throws {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        let shared = try String(contentsOf: root.appendingPathComponent("Shaders/OathSilk.metal"), encoding: .utf8)
        let artwork = try String(contentsOf: folder.appendingPathComponent("Artwork.metal"), encoding: .utf8)
        let start = shared.range(of: "// A single continuous sheet.")!.lowerBound
        let end = shared.range(of: "// The normal atlas is rendered")!.lowerBound
        let source = String(shared[..<start]) + artwork + "\n" + String(shared[end...])
            .replacingOccurrences(of: "silkColor(uv, u, palette)", with: "oathArt(uv, u, palette)")
        try source.write(to: folder.appendingPathComponent("Compiled.metal"), atomically: true, encoding: .utf8)
        library = try device.makeLibrary(source: source, options: nil)
        logo = try OathLogoTexture.load(url: root.appendingPathComponent("OathApp/Resources/OathGlassNormals.png"), device: device, queue: queue, library: library)
        precondition(logo.width == 4096 && logo.height == 3072 && logo.mipmapLevelCount > 1)
        func pipeline(_ format: MTLPixelFormat, device: MTLDevice, library: MTLLibrary) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "oathVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "oathFragment")
            descriptor.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        stillPipeline = try pipeline(.rgba8Unorm, device: device, library: library)
        moviePipeline = try pipeline(.bgra8Unorm, device: device, library: library)
    }

    func texture(width: Int, height: Int, movie: Bool = false) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: movie ? .bgra8Unorm : .rgba8Unorm,
                                                                width: width, height: height, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)!
    }

    func draw(to texture: MTLTexture, time: Float, appearance: Float, movie: Bool = false) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let command = queue.makeCommandBuffer()!
        let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
        encoder.setRenderPipelineState(movie ? moviePipeline : stillPipeline)
        encoder.setFragmentTexture(logo, index: 0)
        var colors = OathColorway.cobalt.colors
        encoder.setFragmentBytes(&colors, length: MemoryLayout<OathSilkColors>.stride, index: 1)
        let sides = movie ? 2 : 1
        for side in 0..<sides {
            let width = texture.width / sides
            encoder.setViewport(MTLViewport(originX: Double(side * width), originY: 0, width: Double(width), height: Double(texture.height), znear: 0, zfar: 1))
            var frame = DirectionUniforms(resolution: SIMD2(Float(width), Float(texture.height)),
                                          timeAndAppearance: SIMD2(time, movie ? Float(side) : appearance))
            encoder.setFragmentBytes(&frame, length: MemoryLayout<DirectionUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw command.error ?? NSError(domain: "OathDirection", code: 1)
        }
        lastGPUMilliseconds = (command.gpuEndTime - command.gpuStartTime) * 1000
    }

    func pixels(_ texture: MTLTexture) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&result, bytesPerRow: texture.width * 4,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return result
    }
}

@main
struct OathRenderDirection {
    static func main() throws {
        precondition(CommandLine.arguments.count >= 2, "Pass your direction folder")
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let path = CommandLine.arguments[1]
        let folder = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        let gpu = try DirectionGPU(root: root, folder: folder)
        let width = 1320, height = 2868
        let texture = gpu.texture(width: width, height: height)
        var checks: [[String: Any]] = []
        for (name, appearance) in [("light", Float(0)), ("dark", Float(1))] {
            try gpu.draw(to: texture, time: 2.5, appearance: appearance)
            let pixels = gpu.pixels(texture)
            let gpuTime = gpu.lastGPUMilliseconds
            precondition(stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 255 }, "Output must be opaque")
            var quietRange = 0
            for channel in 0..<3 {
                var minimum = 255, maximum = 0
                for y in stride(from: height * 3 / 4, to: height, by: 12) {
                    for x in stride(from: 0, to: width, by: 12) {
                        let value = Int(pixels[(y * width + x) * 4 + channel])
                        minimum = min(minimum, value); maximum = max(maximum, value)
                    }
                }
                quietRange = max(quietRange, maximum - minimum)
            }
            precondition(quietRange <= 2, "Bottom quarter must remain calm")
            try savePNG(pixels, width: width, height: height, to: folder.appendingPathComponent("\(name).png"))
            try gpu.draw(to: texture, time: 6.5, appearance: appearance)
            let later = gpu.pixels(texture)
            let start = Int(Float(height) * 0.34) * width * 4
            let end = Int(Float(height) * 0.69) * width * 4
            let changed = zip(pixels[start..<end], later[start..<end]).filter { abs(Int($0.0) - Int($0.1)) > 3 }.count
            precondition(changed > (end - start) / 400, "Animation must visibly change the supporting art below the logo")
            try gpu.draw(to: texture, time: 0, appearance: appearance)
            try savePNG(gpu.pixels(texture), width: width, height: height, to: folder.appendingPathComponent("\(name)-still.png"))
            checks.append(["appearance": name, "opaque": true, "lower_quarter_range": quietRange,
                           "moving_art_channels": changed, "native_frame_gpu_ms_on_Mac_only": gpuTime])
            print("\(name): native PNG, quiet lower area, motion, and time-zero frame passed")
        }

        if !CommandLine.arguments.contains("--stills-only") {
            try makeMovie(gpu: gpu, folder: folder)
        }
        let report: [String: Any] = [
            "native_screen_dimensions": [width, height], "hero_time_seconds": 2.5,
            "logo_dimensions": [4096, 3072], "metal_compilation": "passed", "checks": checks,
            "movie_seconds": CommandLine.arguments.contains("--stills-only") ? 0 : 8,
            "movie_appearance_order": "light left, dark right", "render_host": "Mac GPU",
            "physical_device": "not used", "simulator": "not used"
        ]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: folder.appendingPathComponent("render-checks.json"))
        print("Direction complete: \(folder.lastPathComponent)")
    }

    private static func savePNG(_ pixels: [UInt8], width: Int, height: Int, to url: URL) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: width * 4, bitsPerPixel: 32)!
        pixels.withUnsafeBytes { bitmap.bitmapData!.update(from: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), count: pixels.count) }
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }

    private static func makeMovie(gpu: DirectionGPU, folder: URL) throws {
        let width = 1320, height = 1434
        let texture = gpu.texture(width: width, height: height, movie: true)
        let output = folder.appendingPathComponent("motion.mp4")
        if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 9_000_000]
        ])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<192 {
            while !input.isReadyForMoreMediaData {
                precondition(writer.status == .writing, "Video writer stopped")
                Thread.sleep(forTimeInterval: 0.002)
            }
            try gpu.draw(to: texture, time: Float(frame) / 24, appearance: 0, movie: true)
            var optionalBuffer: CVPixelBuffer?
            precondition(CVPixelBufferPoolCreatePixelBuffer(nil, adapter.pixelBufferPool!, &optionalBuffer) == kCVReturnSuccess)
            let buffer = optionalBuffer!
            CVPixelBufferLockBaseAddress(buffer, [])
            texture.getBytes(CVPixelBufferGetBaseAddress(buffer)!, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            precondition(adapter.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 24)))
        }
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        precondition(writer.status == .completed, "Video failed")
        print("Eight-second motion preview saved")
    }
}

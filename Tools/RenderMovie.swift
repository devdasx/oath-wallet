import Foundation
import MetalKit
import AVFoundation

struct Uniforms {
    var resolution: SIMD2<Float>
    var timeAndAppearance: SIMD2<Float>
    var interaction = SIMD2<Float>.zero
    var padding = SIMD2<Float>.zero
    var logoRect = SIMD4<Float>.zero
    var fadeLayout = SIMD4<Float>.zero
    var copyRect = SIMD4<Float>.zero
    var logoClip = SIMD4<Float>.zero
    var panelLayout = SIMD4<Float>.zero
}
@main
struct OathRenderMovie {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let device = MTLCreateSystemDefaultDevice()!
        let queue = device.makeCommandQueue()!
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
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        var silkColors = OathColorway.cobalt.colors
        let width = 1320, height = 1434
        let texDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        texDescriptor.usage = [.renderTarget]
        texDescriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: texDescriptor)!
        let output = root.appendingPathComponent("Validation/Oath-Atmosphere.mp4")
        if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000]])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<360 {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let command = queue.makeCommandBuffer()!
            let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(logoNormals, index: 0)
            for side in 0..<2 {
                encoder.setViewport(MTLViewport(originX: Double(side * width / 2), originY: 0, width: Double(width / 2), height: Double(height), znear: 0, zfar: 1))
                var uniforms = Uniforms(resolution: SIMD2(Float(width / 2), Float(height)), timeAndAppearance: SIMD2(Float(frame) / 30, side == 0 ? 1 : 0))
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentBytes(&silkColors, length: MemoryLayout<OathSilkColors>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            precondition(command.status == .completed)
            var pixelBuffer: CVPixelBuffer?
            precondition(CVPixelBufferPoolCreatePixelBuffer(nil, adapter.pixelBufferPool!, &pixelBuffer) == kCVReturnSuccess)
            let buffer = pixelBuffer!
            CVPixelBufferLockBaseAddress(buffer, [])
            texture.getBytes(CVPixelBufferGetBaseAddress(buffer)!, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            precondition(adapter.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        precondition(writer.status == .completed, "Video failed")
        print("Saved 12-second dark/light shader preview at \(output.path)")
    }
}

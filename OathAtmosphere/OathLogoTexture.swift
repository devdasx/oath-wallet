import Foundation
import MetalKit

/// Filters surface normals with silhouette coverage, so transparent texels cannot
/// create false bevels or dark, fractured edges when the 4K logo is scaled down.
enum OathLogoTexture {
    /// CPU decoding and pipeline creation can run away from the main actor.
    /// GPU work is deferred to the first foreground frame, on its command buffer.
    // Metal's texture protocol lacks Sendable annotations. These references
    // transfer after decoding finishes; encoding/submission has one owner.
    struct Preparation: @unchecked Sendable {
        let source: MTLTexture
        let texture: MTLTexture
        let pipeline: MTLComputePipelineState

        func encode(into command: MTLCommandBuffer) throws {
            guard let encoder = command.makeComputeCommandEncoder() else { throw LoadError.unavailable }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(texture, index: 1)
            encoder.dispatchThreads(
                MTLSize(width: source.width, height: source.height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
            )
            encoder.endEncoding()
            guard let blit = command.makeBlitCommandEncoder() else { throw LoadError.unavailable }
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
        }
    }

    static func prepare(url: URL, device: MTLDevice, library: MTLLibrary) throws -> Preparation {
        let source = try MTKTextureLoader(device: device).newTexture(URL: url, options: [
            .SRGB: false,
            .origin: MTKTextureLoader.Origin.topLeft,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
        ])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: source.width, height: source.height, mipmapped: true
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let result = device.makeTexture(descriptor: descriptor),
              let function = library.makeFunction(name: "oathPrepareLogoNormals") else {
            throw LoadError.unavailable
        }
        result.label = "Oath logo • coverage-filtered 4K normals"
        let pipeline = try device.makeComputePipelineState(function: function)
        return Preparation(source: source, texture: result, pipeline: pipeline)
    }

    /// Synchronous wrapper for offline Mac rendering tools only. The app uses
    /// prepare/encode and never waits on the GPU to construct its welcome view.
    static func load(url: URL, device: MTLDevice, queue: MTLCommandQueue, library: MTLLibrary) throws -> MTLTexture {
        let preparation = try prepare(url: url, device: device, library: library)
        guard let command = queue.makeCommandBuffer() else { throw LoadError.unavailable }
        try preparation.encode(into: command)
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? LoadError.processingFailed }
        return preparation.texture
    }

    private enum LoadError: Error { case unavailable, processingFailed }
}

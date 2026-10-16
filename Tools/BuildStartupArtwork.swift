import AppKit
import MetalKit

/// Offline asset generation. Run only when the material, palette, or logo changes.
/// Assets are ordinary bundled images; the app never generates or downloads them.
@main
struct BuildStartupArtwork {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = root.appendingPathComponent("OathApp/Resources/Startup")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fatalError("Metal unavailable") }
        let shader = try String(contentsOf: root.appendingPathComponent("Shaders/OathSilk.metal"), encoding: .utf8)
        let logoFragment = """
        fragment float4 oathStartupLogo(VertexOutput in [[stage_in]],
                                        constant AtmosphereUniforms &u [[buffer(0)]],
                                        texture2d<float> normals [[texture(0)]]) {
            constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);
            float4 atlas = normals.sample(s, in.uv);
            float shadow = normals.sample(s, in.uv - float2(0.008,0.026)).a * 0.5
                         + normals.sample(s, in.uv - float2(-0.006,0.018)).a * 0.3
                         + normals.sample(s, in.uv - float2(0.016,0.016)).a * 0.2;
            float alpha = atlas.a + shadow * (1.0-atlas.a) * mix(0.13,0.23,u.timeAndAppearance.y);
            float3 glass = atlas.a > 0.001 ? oathLogoGlass(atlas, 0.0) : float3(0.0);
            // PNG stores straight alpha; its native decoder premultiplies it.
            return float4(glass * atlas.a / max(alpha,0.0001), alpha);
        }
        """
        let library = try device.makeLibrary(source: shader + "\n" + logoFragment, options: nil)
        let normals = try OathLogoTexture.load(url: root.appendingPathComponent("OathApp/Resources/OathGlassNormals.png"),
                                              device: device, queue: queue, library: library)
        precondition(normals.width == 4096 && normals.height == 3072 && normals.mipmapLevelCount > 1)
        func pipeline(_ function: String) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "oathVertex")
            d.fragmentFunction = library.makeFunction(name: function)
            d.colorAttachments[0].pixelFormat = .rgba8Unorm
            return try device.makeRenderPipelineState(descriptor: d)
        }
        let silkPipeline = try pipeline("oathFragment")
        let logoPipeline = try pipeline("oathStartupLogo")
        let layers = CommandLine.arguments.contains("--material-only") ? ["silk", "reading"] : ["silk", "reading", "logo"]
        for layer in layers {
            let isLogo = layer == "logo"
            let isReading = layer == "reading"
            let width = isLogo ? 4096 : 1024
            let height = isLogo ? 3072 : 2560
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = .renderTarget
            descriptor.storageMode = .shared
            let texture = device.makeTexture(descriptor: descriptor)!
            for colorway in isLogo ? [OathColorway.cobalt] : OathColorway.allCases {
                for dark in [false, true] {
                    var uniforms = AtmosphereUniforms(
                        resolution: SIMD2(Float(width), Float(height)),
                        timeAndAppearance: SIMD2(0, dark ? 1 : 0),
                        logoRect: SIMD4(-2,-2,1,1), copyRect: isReading ? SIMD4(0,0,1,1) : .zero,
                        panelLayout: SIMD4(2,1,0,0)
                    )
                    var colors = colorway.colors
                    let pass = MTLRenderPassDescriptor()
                    pass.colorAttachments[0].texture = texture
                    pass.colorAttachments[0].loadAction = .clear
                    pass.colorAttachments[0].storeAction = .store
                    let command = queue.makeCommandBuffer()!
                    let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
                    encoder.setRenderPipelineState(isLogo ? logoPipeline : silkPipeline)
                    encoder.setFragmentTexture(normals, index: 0)
                    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<AtmosphereUniforms>.stride, index: 0)
                    encoder.setFragmentBytes(&colors, length: MemoryLayout<OathSilkColors>.stride, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    encoder.endEncoding()
                    command.commit()
                    command.waitUntilCompleted()
                    precondition(command.status == .completed)
                    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                  colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied,
                                                  bytesPerRow: width * 4, bitsPerPixel: 32)!
                    texture.getBytes(bitmap.bitmapData!, bytesPerRow: width * 4,
                                     from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                    let name = "OathStartup-\(isLogo ? "logo" : colorway.rawValue)-\(dark ? "dark" : "light")\(isReading ? "-reading" : "").\(isLogo ? "png" : "jpg")"
                    let data = bitmap.representation(using: isLogo ? .png : .jpeg, properties: [.compressionFactor: 0.94])!
                    try data.write(to: output.appendingPathComponent(name))
                    print("\(name): \(width)×\(height), \(data.count) bytes")
                }
            }
        }
    }
}

import Foundation
import MetalKit

/// Runs the production shader on the Mac GPU. The independent pre-optimization
/// height function is an oracle for geometry, lighting and GPU cost. No iOS
/// simulator/device, wallet, network, or application launch is involved.
@main struct CheckArtworkPerformance {
    private static let reference = """
    float silkHeightReference(float2 p, float t) {
        float2 center = float2(0.10 + 0.10 * sin(t * 0.16), 0.09);
        float2 local = p - center;
        float turn = (0.88 + 0.12 * sin(t * 0.13)) * exp(-dot(local, local) * 0.52);
        float c = cos(turn), s = sin(turn);
        p = float2(local.x*c - local.y*s, local.x*s + local.y*c) + center;
        float spine = 0.27 * sin(p.y * 2.08 + t * 0.25 + 0.70)
                    + 0.095 * sin(p.y * 3.35 - t * 0.17 - 0.20);
        float q = p.x - spine + p.y * 0.17;
        q *= 1.0 + 0.13 * sin(p.y * 1.70 - t * 0.11);
        float primary = sin(q * 8.15 + 0.22 * sin(p.y * 2.10 + t * 0.18));
        float undertow = sin(q * 13.70 - p.y * 0.82 - t * 0.21);
        float fineFold = sin(q * 22.40 + p.y * 1.28 + t * 0.15);
        return primary * 0.175 + undertow * 0.025 + fineFold * 0.0045
             + 0.030 * cos(p.y * 1.85 + p.x * 1.70 - t * 0.19);
    }
    float3 silkReferenceSurface(float2 p, float t) {
        constexpr float e = 0.0015;
        return float3(silkHeightReference(p, t),
            (silkHeightReference(p + float2(e, 0), t) - silkHeightReference(p - float2(e, 0), t)) / (2.0 * e),
            (silkHeightReference(p + float2(0, e), t) - silkHeightReference(p - float2(0, e), t)) / (2.0 * e));
    }
    """

    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("This host regression requires Metal")
        }
        let source = try String(contentsOfFile: "Shaders/OathSilk.metal", encoding: .utf8)
        let anchor = "float3 silkHeightAndGradient(float2 p, float t)"
        precondition(source.contains(anchor))
        let testSource = source.replacingOccurrences(of: anchor, with: reference + "\n" + anchor)
        let baselineSource = testSource.replacingOccurrences(of: "float3 surface = silkHeightAndGradient(p, t);",
                                                              with: "float3 surface = silkReferenceSurface(p, t);")
        let gradientKernel = """
        kernel void checkGradient(device float4 *errors [[buffer(0)]], uint id [[thread_position_in_grid]]) {
            float2 p = float2(float(id % 128) / 127.0 * 6.0 - 3.0,
                              float((id / 128) % 128) / 127.0 * 8.0 - 4.0);
            float t = float(id / (128 * 128)) * 7.3;
            float3 actual = silkHeightAndGradient(p, t);
            float3 expected = silkReferenceSurface(p, t);
            errors[id] = float4(abs(actual - expected), 1);
        }
        """
        let library = try device.makeLibrary(source: testSource + gradientKernel, options: nil)
        let baseline = try device.makeLibrary(source: baselineSource, options: nil)
        let compute = try device.makeComputePipelineState(function: library.makeFunction(name: "checkGradient")!)
        let count = 128 * 128 * 12
        let errors = device.makeBuffer(length: count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)!
        let command = queue.makeCommandBuffer()!
        let encoder = command.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(compute)
        encoder.setBuffer(errors, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: compute.threadExecutionWidth, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit(); command.waitUntilCompleted()
        precondition(command.status == .completed)
        var maxima = SIMD3<Float>.zero
        let values = errors.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        for i in 0..<count {
            for c in 0..<3 {
                precondition(values[i][c].isFinite)
                maxima[c] = max(maxima[c], values[i][c])
            }
        }
        precondition(maxima.x < 0.00001 && maxima.y < 0.002 && maxima.z < 0.002,
                     "The optimized surface must match the independent height/finite-difference oracle: \(maxima)")
        print("PASS: \(count) GPU height/slope samples across 12 animation times. Max differences: \(maxima)")

        func pipeline(_ library: MTLLibrary) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "oathVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "oathFragment")
            descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        let states = try [pipeline(baseline), pipeline(library)]
        let width = 880, height = 1912 // Full-height, 2x wallet artwork; no resolution reduction.
        let size = CGSize(width: width, height: height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        let target = device.makeTexture(descriptor: descriptor)!
        let emptyLogo = device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: 1, height: 1, mipmapped: false))!
        var transparent: UInt32 = 0
        emptyLogo.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &transparent, bytesPerRow: 4)
        let frame = OathArtworkFrame(size: size, safeTop: 0, placement: .walletBackdrop(size: size))
        func render(_ index: Int, time: Float, dark: Bool, rgb: UInt32) -> Double {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            let command = queue.makeCommandBuffer()!
            let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
            encoder.setRenderPipelineState(states[index])
            encoder.setFragmentTexture(emptyLogo, index: 0)
            var uniforms = frame.uniforms(pixelSize: size, time: time, appearance: dark ? 1 : 0, interaction: .zero)
            var colors = OathSilkColors.custom(rgb)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<AtmosphereUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&colors, length: MemoryLayout<OathSilkColors>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            precondition(command.status == .completed)
            return (command.gpuEndTime - command.gpuStartTime) * 1_000
        }
        func pixels() -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            return bytes
        }
        var peak = 0, totalError: Int64 = 0, samples: Int64 = 0
        for dark in [false, true] {
            for rgb: UInt32 in [0x244DE0, 0x656977, 0xFFFFFF, 0xDF438D] {
                for time: Float in [0, 13.7] {
                    _ = render(0, time: time, dark: dark, rgb: rgb)
                    let before = pixels()
                    _ = render(1, time: time, dark: dark, rgb: rgb)
                    let after = pixels()
                    for i in before.indices {
                        let error = abs(Int(before[i]) - Int(after[i]))
                        peak = max(peak, error); totalError += Int64(error); samples += 1
                    }
                }
            }
        }
        let mean = Double(totalError) / Double(samples)
        precondition(peak <= 4 && mean < 0.05, "Lighting changed beyond finite-difference rounding: peak \(peak), mean \(mean)")
        print(String(format: "PASS: 16 full-size frames, light/dark and four palettes. Pixel difference mean %.5f, peak %d/255.", mean, peak))
        var durations = [[Double](), [Double]()]
        // Warm both pipelines, then alternate their order to reduce thermal/clock bias.
        for round in 0..<100 {
            for index in round.isMultiple(of: 2) ? [0, 1] : [1, 0] {
                let duration = render(index, time: Float(round) / 60, dark: false, rgb: 0x244DE0)
                if round >= 20 { durations[index].append(duration) }
            }
        }
        let medians = durations.map { $0.sorted()[$0.count / 2] }
        print(String(format: "Host GPU median at %dx%d: previous %.3f ms, optimized %.3f ms (%.2fx). Not an iPhone timing claim.",
                     width, height, medians[0], medians[1], medians[0] / medians[1]))
    }
}

import OathDiagnostics
import MetalKit

/// Immutable Metal objects are prepared on a worker, once per app process.
/// Neither pipeline compilation nor 4K PNG decoding blocks the first UI frame.
// Metal objects are immutable after preparation. The sole mutable preparation
// field is accessed only on OathArtworkWorker.queue, including first submission.
final class OathArtworkResources: @unchecked Sendable {
    private struct Prepared: Sendable {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState
        let logo: OathLogoTexture.Preparation

        static func load() throws -> Self {
            guard let device = MTLCreateSystemDefaultDevice(),
                  let queue = device.makeCommandQueue(),
                  let library = device.makeDefaultLibrary(),
                  let vertex = library.makeFunction(name: "oathVertex"),
                  let fragment = library.makeFunction(name: "oathFragment"),
                  let logoURL = Bundle.main.url(forResource: "OathGlassNormals", withExtension: "png") else {
                throw ResourceError.unavailable
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Oath • continuous silk"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try Self(device: device, queue: queue,
                            pipeline: device.makeRenderPipelineState(descriptor: descriptor),
                            logo: OathLogoTexture.prepare(url: logoURL, device: device, library: library))
        }
    }

    @MainActor private static var preparation: Task<OathArtworkResources, Error>?
    @MainActor private static weak var loaded: OathArtworkResources?
    @MainActor static func shared() async throws -> OathArtworkResources {
        if let preparation { return try await preparation.value }
        let task = Task {
            #if DEBUG
            // Delay/failure injection exercises the real first-frame path.
            let delay = UserDefaults.standard.double(forKey: "oath-artwork-delay")
            if delay > 0 { try await Task.sleep(for: .seconds(min(delay, 30))) }
            if ProcessInfo.processInfo.arguments.contains("-oath-artwork-unavailable") {
                throw ResourceError.unavailable
            }
            #endif
            let prepared = try await Task.detached(priority: .userInitiated) {
                try Prepared.load()
            }.value
            let resources = OathArtworkResources(prepared)
            loaded = resources
            return resources
        }
        preparation = task
        do { return try await task.value }
        catch { OathDiagnostics.record(error);
            preparation = nil
            throw error
        }
    }

    @MainActor static func invalidate(_ resources: OathArtworkResources) {
        guard loaded === resources else { return }
        preparation = nil
        loaded = nil
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let logoNormals: MTLTexture
    private var logoPreparation: OathLogoTexture.Preparation?

    private init(_ prepared: Prepared) {
        device = prepared.device
        queue = prepared.queue
        pipeline = prepared.pipeline
        logoNormals = prepared.logo.texture
        logoPreparation = prepared.logo
    }

    func encodeLogoIfNeeded(into command: MTLCommandBuffer) throws {
        dispatchPrecondition(condition: .onQueue(OathArtworkWorker.queue))
        try logoPreparation?.encode(into: command)
    }

    func didSubmit() {
        dispatchPrecondition(condition: .onQueue(OathArtworkWorker.queue))
        // Every renderer uses this same command queue, so subsequent frames
        // automatically wait for the first frame's texture preparation.
        // The submitted command retains the source until the GPU finishes.
        logoPreparation = nil
    }

    private enum ResourceError: Error { case unavailable }
}

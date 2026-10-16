import OathDiagnostics
import MetalKit

/// Drawable waits are isolated per surface: a covered Home canvas cannot stall
/// the visible Customize/Welcome canvas. Encoding shares one queue to preserve
/// logo preparation ordering, with one outstanding frame per surface.
final class OathArtworkWorker: Sendable {
    enum Result: Sendable { case presented, unavailable, failed(String) }
    static let queue = DispatchQueue(label: "org.oathwallet.artwork", qos: .userInteractive)
    private let drawableQueue = DispatchQueue(label: "org.oathwallet.artwork.drawable", qos: .userInteractive)
    let gate = OathArtworkFrameGate()

    // CAMetalLayer is designed for background drawable acquisition. UIKit alone
    // changes its geometry/device; this reference never exposes the UIView.
    private struct Target: @unchecked Sendable { let layer: CAMetalLayer }
    private struct Drawable: @unchecked Sendable { let value: CAMetalDrawable }

    @discardableResult
    func submit(layer: CAMetalLayer, resources: OathArtworkResources,
                uniforms: AtmosphereUniforms, colors: OathSilkColors,
                completion: @escaping @MainActor @Sendable (Result) -> Void) -> Bool {
        guard let ticket = gate.begin() else { return false }
        let target = Target(layer: layer)
        let finish: @Sendable (Result) -> Void = { [gate] result in
            Task { @MainActor in
                // Keep the in-flight slot until the UI actor consumes the
                // outcome. Neither stale failures nor a callback backlog can
                // overtake a later frame after backgrounding/reattachment.
                let current = gate.isCurrent(ticket)
                gate.finish(ticket)
                guard current else { return }
                completion(result)
            }
        }
        drawableQueue.async { [gate] in
            autoreleasepool {
                guard gate.isCurrent(ticket), let drawable = target.layer.nextDrawable(), gate.isCurrent(ticket) else {
                    finish(.unavailable)
                    return
                }
                let retained = Drawable(value: drawable)
                Self.queue.async {
                    autoreleasepool {
                        guard gate.isCurrent(ticket) else { finish(.unavailable); return }
                        guard let command = resources.queue.makeCommandBuffer() else {
                            finish(.failed("Metal command buffer unavailable")); return
                        }
                        do { try resources.encodeLogoIfNeeded(into: command) }
                        catch { OathDiagnostics.record(error); finish(.failed(error.localizedDescription)); return }
                        let pass = MTLRenderPassDescriptor()
                        pass.colorAttachments[0].texture = retained.value.texture
                        pass.colorAttachments[0].loadAction = .clear
                        pass.colorAttachments[0].storeAction = .store
                        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                            finish(.failed("Metal encoder unavailable")); return
                        }
                        var uniforms = uniforms
                        var colors = colors
                        encoder.setRenderPipelineState(resources.pipeline)
                        encoder.setFragmentTexture(resources.logoNormals, index: 0)
                        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<AtmosphereUniforms>.stride, index: 0)
                        encoder.setFragmentBytes(&colors, length: MemoryLayout<OathSilkColors>.stride, index: 1)
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                        encoder.endEncoding()
                        guard gate.isCurrent(ticket) else { finish(.unavailable); return }
                        command.addCompletedHandler { command in
                            finish(command.status == .completed ? .presented
                                   : .failed(command.error?.localizedDescription ?? "Metal command failed"))
                        }
                        command.present(retained.value)
                        command.commit()
                        resources.didSubmit()
                    }
                }
            }
        }
        return true
    }
}

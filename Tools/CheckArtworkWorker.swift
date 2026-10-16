import Foundation
import MetalKit

// The tested paths stop at drawable acquisition. These uncalled resource
// members make the production worker runnable on the Mac without an app bundle.
final class OathArtworkResources: Sendable {
    var queue: MTLCommandQueue { fatalError("No drawable may reach encoding in this check") }
    var pipeline: MTLRenderPipelineState { fatalError("Not reached") }
    var logoNormals: MTLTexture { fatalError("Not reached") }
    func encodeLogoIfNeeded(into command: MTLCommandBuffer) throws { fatalError("Not reached") }
    func didSubmit() { fatalError("Not reached") }
}

private final class WaitingLayer: CAMetalLayer, @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    var didEnter: Bool { lock.withLock { entered } }
    let release = DispatchSemaphore(value: 0)
    var blocks = false

    override func nextDrawable() -> CAMetalDrawable? {
        lock.withLock { entered = true }
        if blocks { precondition(release.wait(timeout: .now() + 5) == .success) }
        return nil
    }
}

/// Exercises the real worker/gate with bounded, deterministic drawable waits.
/// No iOS app, simulator, device, visible window, or GPU command is needed.
@main struct CheckArtworkWorker {
    @MainActor private final class Deliveries {
        var count = 0
        func accept(_ result: OathArtworkWorker.Result) {
            MainActor.assertIsolated()
            guard case .unavailable = result else { preconditionFailure("Skipped drawable reported as success") }
            count += 1
        }
    }

    @MainActor static func main() async throws {
        let blocked = OathArtworkWorker(), visible = OathArtworkWorker()
        blocked.gate.setEnabled(true)
        visible.gate.setEnabled(true)
        let waitingLayer = WaitingLayer()
        waitingLayer.blocks = true
        let visibleLayer = WaitingLayer()
        let resources = OathArtworkResources()
        let uniforms = AtmosphereUniforms(resolution: SIMD2(320, 640), timeAndAppearance: .zero)
        let blockedDeliveries = Deliveries(), visibleDeliveries = Deliveries()
        precondition(blocked.submit(layer: waitingLayer, resources: resources, uniforms: uniforms,
                                    colors: OathColorway.cobalt.colors) { blockedDeliveries.accept($0) })
        try await wait { waitingLayer.didEnter }
        for _ in 0..<100 {
            precondition(!blocked.submit(layer: waitingLayer, resources: resources, uniforms: uniforms,
                                         colors: .custom(0xFF0000)) { blockedDeliveries.accept($0) })
        }
        precondition(visible.submit(layer: visibleLayer, resources: resources, uniforms: uniforms,
                                    colors: .custom(0xFF0000)) { visibleDeliveries.accept($0) })
        try await wait { visibleDeliveries.count == 1 }
        precondition(blockedDeliveries.count == 0, "The visible surface must finish before the other drawable is released")

        // Teardown happens while the old surface still waits in a driver call.
        blocked.gate.setEnabled(false)
        waitingLayer.release.signal()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        blocked.gate.setEnabled(true)
        var next: OathArtworkFrameGate.Ticket?
        while next == nil && ContinuousClock.now < deadline {
            next = blocked.gate.begin()
            if next == nil { try await Task.sleep(for: .milliseconds(1)) }
        }
        precondition(next != nil, "An abandoned drawable must release its in-flight slot")
        precondition(blockedDeliveries.count == 0, "The old generation must not deliver after reattachment")
        blocked.gate.finish(next!)
        print("PASS: independent surface drawable waits, 100 bounded busy submissions, explicit skipped-frame result and teardown during acquisition")
    }

    @MainActor private static func wait(until ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !ready() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        precondition(ready(), "A covered surface blocked the visible artwork worker")
    }
}

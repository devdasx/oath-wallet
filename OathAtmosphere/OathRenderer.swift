import OathDiagnostics
import MetalKit
import os

@MainActor
final class OathRenderer: NSObject {
    private let worker = OathArtworkWorker()
    private var displayLink: CADisplayLink?
    private var resources: OathArtworkResources?
    private var preparation: Task<Void, Never>?
    private var recovery: Task<Void, Never>?
    private var energyObserver: OathArtworkEnergyObserver?
    private var playback = OathArtworkPlayback()
    private var appearance: Float = 0
    private var targetAppearance: Float = 0
    private var silkColors = OathColorway.cobalt.colors
    private var paletteColorway = OathColorway.cobalt
    private var paletteCustomColor: UInt32?
    private var reduceMotion = false
    private var active = false
    private var foreground = false
    private var stopped = false
    private var attached = false
    private var energyPolicy = OathArtworkEnergyPolicy(
        thermalState: ProcessInfo.processInfo.thermalState,
        lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    private var interaction = SIMD2<Float>.zero
    private var targetInteraction = SIMD2<Float>.zero
    private var placement: OathArtworkPlacement?
    private var viewport: OathArtworkViewport?
    private weak var surface: OathArtworkView?
    private let logger = Logger(subsystem: "org.oathwallet.atmosphere.studio", category: "renderer")

    func configure(_ view: OathArtworkView, dark: Bool) {
        surface = view
        appearance = dark ? 1 : 0
        targetAppearance = appearance
        let target = DisplayLinkTarget(renderer: self)
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick))
        link.isPaused = true
        // Common modes keep the artwork ticking while UIScrollView tracks a
        // finger. Default-mode timers pause during native pull-to-refresh.
        link.add(to: .main, forMode: .common)
        displayLink = link
        view.onLayout = { [weak self] in
            self?.layoutChanged()
        }
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        gesture.cancelsTouchesInView = false
        view.addGestureRecognizer(gesture)
        energyObserver?.cancel()
        energyObserver = OathArtworkEnergyObserver { [weak self] in
            self?.energyStateChanged()
        }
        energyStateChanged()
    }

    func update(_ view: OathArtworkView, dark: Bool, reduceMotion: Bool, active: Bool,
                foreground: Bool, colorway: OathColorway, customColor: UInt32? = nil, placement: OathArtworkPlacement?) {
        let paletteChanged = paletteColorway != colorway || paletteCustomColor != customColor
        if paletteChanged {
            silkColors = customColor.map(OathSilkColors.custom) ?? colorway.colors
            paletteColorway = colorway
            paletteCustomColor = customColor
        }
        let changed = targetAppearance != (dark ? 1 : 0) || paletteChanged
            || self.placement != placement || self.reduceMotion != reduceMotion
        let resuming = (active && !self.active) || (foreground && !self.foreground)
        targetAppearance = dark ? 1 : 0
        self.placement = placement
        self.reduceMotion = reduceMotion
        self.active = active
        self.foreground = foreground
        if resuming { resumePlayback() }
        view.updateStartup(dark: dark, colorway: colorway, customColor: customColor, placement: placement)
        if !energyPolicy.rendersFrames { view.showStartupArtwork() }
        if !animating || !playback.hasPresentedFrame {
            appearance = targetAppearance
            interaction = .zero
            targetInteraction = .zero
        }
        prepareIfNeeded()
        if changed { playback.requestFrame() }
        updateDrawingMode()
    }

    private var animating: Bool { active && !reduceMotion && energyPolicy.animates }

    private func prepareIfNeeded() {
        // A hot launch can display the bundled poster without compiling or
        // allocating Metal resources. Cooling resumes preparation once.
        if !stopped, foreground, attached, energyPolicy.rendersFrames,
           resources == nil, preparation == nil, recovery == nil, !playback.recoveryExhausted {
            preparation = Task { [weak self] in
                defer { self?.preparation = nil }
                do {
                    let resources = try await OathArtworkResources.shared()
                    try Task.checkCancellation()
                    guard let self, !stopped, let surface = self.surface else { return }
                    self.resources = resources
                    surface.metal.metalLayer.device = resources.device
                    self.updateDrawingMode()
                    self.requestFrame()
                } catch is CancellationError {
                    // The welcome view was removed while the shared cache warmed.
                } catch { OathDiagnostics.record(error);
                    self?.renderingFailed(error)
                }
            }
        }
    }

    private func updateDrawingMode() {
        let canDraw = !stopped && foreground && attached && resources != nil
            && recovery == nil && !playback.recoveryExhausted && energyPolicy.rendersFrames
        // Restore the native layer before asking it for a drawable. Waiting for
        // a successful frame to unhide a suspended layer creates a dependency
        // on presentation by the very layer we kept hidden.
        if canDraw { surface?.metal.isHidden = false }
        worker.gate.setEnabled(canDraw)
        let paused = !playback.shouldTick(canDraw: canDraw, animating: animating)
        if displayLink?.isPaused != paused { displayLink?.isPaused = paused }
        if paused { playback.pause() }
    }

    private func requestFrame() {
        // Inactive foreground launch and Reduce Motion still need one frame.
        // Never submit Metal commands after the scene enters the background.
        playback.requestFrame()
        updateDrawingMode()
    }

    private func layoutChanged() {
        guard let surface else { return }
        let inWindow = surface.window != nil
        let attachmentChanged = inWindow != attached
        if inWindow && !attached { resumePlayback() }
        attached = inWindow
        let next = OathArtworkViewport(size: surface.bounds.size,
            safeTop: max(surface.safeAreaInsets.top, surface.window?.safeAreaInsets.top ?? 0))
        // Text and keyboard layout can visit the same canvas many times.
        // Only new geometry or attachment needs a frame; an unchanged layout
        // must not wake a covered/Reduce Motion surface on every keystroke.
        guard attachmentChanged || viewport != next else { return }
        viewport = next
        prepareIfNeeded()
        requestFrame()
    }

    private func resumePlayback() {
        recovery?.cancel()
        recovery = nil
        playback.resume()
    }

    private func energyStateChanged() {
        let previous = energyPolicy
        energyPolicy = OathArtworkEnergyPolicy(thermalState: ProcessInfo.processInfo.thermalState,
                                               lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        if previous != energyPolicy, energyPolicy.rendersFrames { resumePlayback() }
        if !energyPolicy.rendersFrames { surface?.showStartupArtwork() }
        setFrameRate()
        prepareIfNeeded()
        updateDrawingMode()
        requestFrame()
    }

    private func setFrameRate() {
        // Zero means the display's maximum to CADisplayLink, so the policy
        // pauses the link separately when continuous rendering is disallowed.
        displayLink?.preferredFramesPerSecond = max(1, energyPolicy.framesPerSecond)
    }

    @objc private func pan(_ recognizer: UIPanGestureRecognizer) {
        guard !reduceMotion, let view = recognizer.view else { return }
        switch recognizer.state {
        case .began, .changed:
            let point = recognizer.location(in: view)
            targetInteraction = SIMD2(
                Float(point.x / max(view.bounds.width, 1) - 0.5),
                Float(point.y / max(view.bounds.height, 1) - 0.5)
            )
        default:
            targetInteraction = .zero
        }
    }

    private func draw() {
        guard !stopped, foreground, recovery == nil, !playback.recoveryExhausted,
              energyPolicy.rendersFrames, let view = surface?.metal, view.window != nil,
              view.bounds.width > 0, view.bounds.height > 0, let resources else { return }
        let scale = min(energyPolicy.maximumScale,
                        view.window?.windowScene?.screen.nativeScale ?? view.traitCollection.displayScale)
        if view.contentScaleFactor != scale { view.contentScaleFactor = scale }
        let size = CGSize(width: (view.bounds.width * scale).rounded(), height: (view.bounds.height * scale).rounded())
        if view.metalLayer.drawableSize != size { view.metalLayer.drawableSize = size }
        let dt = Float(playback.advance(at: CACurrentMediaTime(), animating: animating))
        let smoothing = 1 - exp(-dt * 4)
        appearance += (targetAppearance - appearance) * smoothing
        interaction += (targetInteraction - interaction) * smoothing
        let frame = OathArtworkFrame(size: view.bounds.size,
                                     safeTop: max(view.safeAreaInsets.top, view.window?.safeAreaInsets.top ?? 0),
                                     placement: placement)
        let uniforms = frame.uniforms(pixelSize: size, time: Float(playback.elapsed),
                                      appearance: appearance, interaction: interaction)
        // Capture only value-type layout/uniforms on the UI thread. Drawable
        // acquisition, encoding and command submission can all wait on drivers,
        // so they belong to the background worker, never the display callback.
        let revision = playback.revision
        worker.submit(layer: view.metalLayer, resources: resources, uniforms: uniforms,
                      colors: silkColors) { [weak self] result in
            guard let self, !stopped, foreground, surface != nil else { return }
            switch result {
            case .failed(let error):
                OathDiagnostics.record(DiagnosticFailure(error), component: "rendering", operation: "frame")
                renderingFailed(ArtworkError.command(error))
            case .presented:
                playback.didPresent(revision: revision)
                surface?.didRenderArtwork()
                updateDrawingMode()
            case .unavailable:
                // No drawable is a skipped frame, not successful presentation.
                // Keep the latest color/layout pending until a frame completes.
                updateDrawingMode()
            }
        }
    }

    private func renderingFailed(_ error: Error) {
        guard !stopped else { return }
        if let resources { OathArtworkResources.invalidate(resources) }
        resources = nil
        surface?.showStartupArtwork()
        let delay = playback.renderingFailed()
        if let delay {
            recovery = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
                guard let self, !stopped else { return }
                recovery = nil
                prepareIfNeeded()
                updateDrawingMode()
            }
        }
        updateDrawingMode()
        logger.error("Artwork interrupted; bounded recovery pending: \(delay != nil). \(error.localizedDescription, privacy: .public)")
    }

    func stop() {
        stopped = true
        energyObserver?.cancel()
        energyObserver = nil
        preparation?.cancel()
        recovery?.cancel()
        recovery = nil
        worker.gate.setEnabled(false)
        displayLink?.invalidate()
        displayLink = nil
        surface?.onLayout = nil
        surface = nil
    }

    private enum ArtworkError: Error { case command(String) }

    @MainActor private final class DisplayLinkTarget: NSObject {
        weak var renderer: OathRenderer?
        init(renderer: OathRenderer) { self.renderer = renderer }
        @objc func tick() { renderer?.draw() }
    }
}

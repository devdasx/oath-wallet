import SwiftUI
import UIKit

extension EnvironmentValues {
    /// True outside the cold-launch wrapper, including independently hosted
    /// authentication screens. This delays a prompt; it never grants access.
    @Entry var walletLaunchSplashFinished = true
}

/// One launch hand-off, outside the root's language, wallet and lock identities.
/// The root stays mounted and begins local restoration underneath the cover.
struct OathSplash<Home: View>: View {
    @ViewBuilder var home: () -> Home
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presentation = OathSplashPresentation()
    @State private var firstFrameRendered = false

    init(
        presentation: OathSplashPresentation = OathSplashPresentation(),
        @ViewBuilder home: @escaping () -> Home
    ) {
        self.home = home
        _presentation = State(initialValue: presentation)
    }

    var body: some View {
        home()
            .environment(\.walletLaunchSplashFinished, presentation.finished)
            .opacity(presentation.homeOpacity)
            .scaleEffect(presentation.homeScale(reduceMotion: reduceMotion))
            .allowsHitTesting(presentation.finished)
            .accessibilityHidden(!presentation.finished)
            .overlay {
                if !presentation.finished {
                    OathSplashArtwork(presentation: presentation)
                        // Only the artwork ignores safe areas. The existing root
                        // keeps its navigation bars, keyboard and bottom insets.
                        .ignoresSafeArea()
                        .background {
                            WalletHomeFirstFrameObserver {
                                firstFrameRendered = true
                            }
                        }
                        .accessibilityHidden(true)
                }
            }
            .onAppear { presentation.prepare() }
            .task(id: firstFrameRendered && scenePhase == .active) {
                guard firstFrameRendered, scenePhase == .active else { return }
                await presentation.run(reduceMotion: reduceMotion)
            }
            .onDisappear { presentation.finish() }
    }
}

/// Resolve against the scene's system traits, not the wallet's saved appearance.
/// SwiftUI's preferredColorScheme and UIKit's window override can otherwise
/// recolour the first frame after the system has drawn the launch screen.
struct OathSplashArtwork: UIViewRepresentable {
    let presentation: OathSplashPresentation
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> OathSplashArtworkView {
        OathSplashArtworkView(artwork: presentation.artwork)
    }

    func updateUIView(_ view: OathSplashArtworkView, context: Context) {
        view.updateArtwork(traits: Self.systemTraits(fallback: colorScheme))
    }

    static func systemTraits(fallback: ColorScheme) -> UITraitCollection {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }?
            .traitCollection
            ?? UITraitCollection(userInterfaceStyle: fallback == .dark ? .dark : .light)
    }
}

/// Fixed artwork, animated by the render server. No frame-by-frame SwiftUI
/// updates, layout, image decoding, timers, or manually stepped scale values.
@MainActor
final class OathSplashArtworkView: UIView {
    let artwork: OathSplashLayers

    init(artwork: OathSplashLayers) {
        self.artwork = artwork
        super.init(frame: .zero)
        isOpaque = false
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        layer.addSublayer(artwork.root)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let screen = window?.windowScene?.screen {
            artwork.maximumFramesPerSecond = Float(screen.maximumFramesPerSecond)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        artwork.layout(in: bounds)
    }

    func updateArtwork(traits: UITraitCollection) {
        artwork.configure(traits: traits)
    }
}

@MainActor
final class OathSplashLayers {
    let root = CALayer()
    let cover = CALayer()
    let mark = CALayer()
    var maximumFramesPerSecond: Float = 60
    private var appearance: UIUserInterfaceStyle?
    private var didSchedule = false

    init() {
        root.addSublayer(cover)
        root.addSublayer(mark)
        mark.contentsGravity = .resizeAspect
        mark.magnificationFilter = .linear
        mark.minificationFilter = .trilinear
    }

    func configure(traits: UITraitCollection) {
        guard appearance != traits.userInterfaceStyle else { return }
        appearance = traits.userInterfaceStyle
        let image = UIImage(named: "OathMark", in: .main, compatibleWith: traits)!
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cover.backgroundColor = UIColor(named: "LaunchBackground")!
            .resolvedColor(with: traits).cgColor
        mark.contents = image.cgImage
        mark.contentsScale = image.scale
        CATransaction.commit()
    }

    func layout(in bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = bounds
        cover.frame = root.bounds
        mark.bounds = CGRect(origin: .zero, size: OathSplashPresentation.markSize)
        mark.position = CGPoint(x: root.bounds.midX, y: root.bounds.midY)
        CATransaction.commit()
    }

    /// Submit the entire visual timeline in one transaction before the hold
    /// ends. Startup work cannot delay a later shrink/burst animation commit.
    func schedule(reduceMotion: Bool, at time: CFTimeInterval) {
        guard !didSchedule else { return }
        didSchedule = true
        let start = root.convertTime(time, from: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.opacity = 0
        cover.opacity = 0
        if reduceMotion {
            fade(mark, start: start + 0.35, duration: 0.30, timing: .easeInEaseOut)
            fade(cover, start: start + 0.35, duration: 0.30, timing: .easeInEaseOut)
        } else {
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            // These are the design's four anchors, not discrete frames.
            // Core Animation interpolates every display frame between them.
            scale.values = [1, 1, 0.9, 8]
            scale.keyTimes = [0, NSNumber(value: 0.35 / 1.15), NSNumber(value: 0.65 / 1.15), 1]
            scale.timingFunctions = [
                CAMediaTimingFunction(name: .linear),
                CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1),
                CAMediaTimingFunction(controlPoints: 0.5, 0, 0.75, 0)
            ]
            scale.calculationMode = .linear
            scale.beginTime = start
            scale.duration = 1.15
            scale.fillMode = .backwards
            scale.preferredFrameRateRange = CAFrameRateRange(
                minimum: min(80, maximumFramesPerSecond),
                maximum: maximumFramesPerSecond,
                preferred: maximumFramesPerSecond
            )
            mark.transform = CATransform3DMakeScale(8, 8, 1)
            mark.add(scale, forKey: "oath.scale")
            fade(mark, start: start + 0.77, duration: 0.35, timing: .easeOut)
            fade(cover, start: start + 0.75, duration: 0.45, timing: .easeInEaseOut)
        }
        CATransaction.commit()
    }

    func stop() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.opacity = 0
        cover.opacity = 0
        mark.removeAllAnimations()
        cover.removeAllAnimations()
        CATransaction.commit()
    }

    private func fade(_ layer: CALayer, start: CFTimeInterval, duration: CFTimeInterval,
                      timing: CAMediaTimingFunctionName) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0
        animation.beginTime = start
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        animation.fillMode = .backwards
        layer.add(animation, forKey: "oath.opacity")
    }
}

@MainActor
@Observable
final class OathSplashPresentation {
    static let markSize = CGSize(width: 128, height: 86)
    @ObservationIgnored let artwork = OathSplashLayers()
    private(set) var homeOpacity = 0.0
    private(set) var finished = false
    private(set) var hasStarted = false
    private var homeHasSettled = false
    private var usesReducedMotion = false
    private let haptics: any SplashHapticPlaying
    private let waitUntil: (ContinuousClock.Instant) async throws -> Void

    init(
        haptics: any SplashHapticPlaying = SplashHaptics(),
        waitUntil: @escaping (ContinuousClock.Instant) async throws -> Void = {
            try await ContinuousClock().sleep(until: $0, tolerance: .zero)
        }
    ) {
        self.haptics = haptics
        self.waitUntil = waitUntil
    }

    func homeScale(reduceMotion: Bool) -> CGFloat {
        (reduceMotion || usesReducedMotion || homeHasSettled) ? 1 : 1.06
    }

    func prepare() { haptics.prepare() }

    func run(reduceMotion: Bool) async {
        guard !hasStarted, !finished else { return }
        hasStarted = true
        usesReducedMotion = reduceMotion
        haptics.prepare()
        let start = ContinuousClock.now
        artwork.schedule(reduceMotion: reduceMotion, at: CACurrentMediaTime())
        // Queue the home hand-off now too. There is no SwiftUI view update at
        // the shrink/burst boundary while launch restoration is busy.
        withAnimation(.easeInOut(duration: reduceMotion ? 0.30 : 0.45)
            .delay(reduceMotion ? 0.35 : 0.70)) {
            homeOpacity = 1
        }
        if !reduceMotion {
            withAnimation(.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.50).delay(0.70)) {
                homeHasSettled = true
            }
        }
        OathSplashDiagnostics.record(reduceMotion ? "hold-reduced" : "hold")
        defer { finish() }

        do {
            try await waitUntil(start + .milliseconds(350))
            try Task.checkCancellation()
            guard !finished else { return }

            if reduceMotion {
                OathSplashDiagnostics.record("cross-fade")
                haptics.playReduced()
                try await waitUntil(start + .milliseconds(670))
                return
            }

            haptics.play()
            OathSplashDiagnostics.record("inhale")
            try await waitUntil(start + .milliseconds(650))
            try Task.checkCancellation()
            guard !finished else { return }

            OathSplashDiagnostics.record("burst")
            try await waitUntil(start + .milliseconds(1210))
        } catch {
            // Cancellation (backgrounding/dismissal) finishes this launch once;
            // it must never sleep through cancellation and play late haptics.
        }
    }

    func finish() {
        guard !finished else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            homeOpacity = 1
            homeHasSettled = true
            finished = true
        }
        artwork.stop()
        haptics.stop()
        OathSplashDiagnostics.record("interactive")
    }
}

enum OathSplashDiagnostics {
    static func record(_ event: String) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["OATH_SPLASH_TRACE"] == "1" {
            let line = "OathSplash \(event) \(ProcessInfo.processInfo.systemUptime)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        #endif
    }
}

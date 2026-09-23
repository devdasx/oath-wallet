import CoreHaptics
import UIKit

@MainActor
protocol SplashHapticPlaying {
    func prepare()
    func play()
    func playReduced()
    func stop()
}

enum SplashImpact: Equatable {
    case inhale, seal, echo, reduced
}

/// The custom launch pattern uses the same preference and foreground gate as
/// all other Oath feedback. Native generators stay inside UniHaptic.
extension UniHapticEngine {
    var permitsSplashFeedback: Bool {
        isEnabled && UIApplication.shared.applicationState == .active
    }

    func prepareSplashFeedback() {
        guard permitsSplashFeedback else { return }
        prepare(.whisper)
        prepare(.consequential)
        prepare(.successQuiet)
    }

    func playSplashFeedback(_ impact: SplashImpact) {
        guard permitsSplashFeedback else { return }
        switch impact {
        case .inhale: splashImpact(style: .soft, intensity: 0.45)
        case .seal: splashImpact(style: .rigid, intensity: 1)
        case .echo: splashImpact(style: .light, intensity: 0.45)
        case .reduced: splashImpact(style: .soft, intensity: 0.5)
        }
    }
}

@MainActor
protocol SplashPatternDriving {
    func prepare() throws
    func play() throws
    func stop()
}

@MainActor
final class SplashHaptics: SplashHapticPlaying {
    private let driver: any SplashPatternDriving
    private let canPlay: () -> Bool
    private let prepareFallback: () -> Void
    private let impact: (SplashImpact) -> Void
    private let waitUntil: (ContinuousClock.Instant) async throws -> Void
    private var fallbackTask: Task<Void, Never>?
    private var isPrepared = false
    private var didPlay = false
    private var stopped = false

    init(
        driver: any SplashPatternDriving = CoreSplashPatternDriver(),
        canPlay: @escaping () -> Bool = { UniHapticEngine.shared.permitsSplashFeedback },
        prepareFallback: @escaping () -> Void = { UniHapticEngine.shared.prepareSplashFeedback() },
        impact: @escaping (SplashImpact) -> Void = { UniHapticEngine.shared.playSplashFeedback($0) },
        waitUntil: @escaping (ContinuousClock.Instant) async throws -> Void = {
            try await ContinuousClock().sleep(until: $0, tolerance: .zero)
        }
    ) {
        self.driver = driver
        self.canPlay = canPlay
        self.prepareFallback = prepareFallback
        self.impact = impact
        self.waitUntil = waitUntil
    }

    func prepare() {
        guard canPlay(), !stopped, !isPrepared else { return }
        prepareFallback()
        do {
            try driver.prepare()
            isPrepared = true
        } catch {
            driver.stop()
        }
    }

    func play() {
        guard canPlay(), !stopped, !didPlay else { return }
        prepare()
        didPlay = true
        do {
            try driver.play()
        } catch {
            driver.stop()
            playFallback()
        }
    }

    func playReduced() {
        guard canPlay(), !stopped, !didPlay else { return }
        didPlay = true
        impact(.reduced)
    }

    func stop() {
        stopped = true
        fallbackTask?.cancel()
        fallbackTask = nil
        driver.stop()
        isPrepared = false
    }

    private func playFallback() {
        guard canPlay(), !stopped else { return }
        let start = ContinuousClock.now
        impact(.inhale)
        fallbackTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await waitUntil(start + .milliseconds(300))
                try Task.checkCancellation()
                guard canPlay(), !stopped else { return }
                impact(.seal)
                try await waitUntil(start + .milliseconds(370))
                try Task.checkCancellation()
                guard canPlay(), !stopped else { return }
                impact(.echo)
            } catch { /* A cancelled launch must remain silent. */ }
        }
    }
}

@MainActor
final class CoreSplashPatternDriver: SplashPatternDriving {
    private var engine: CHHapticEngine?
    private var player: (any CHHapticPatternPlayer)?
    private var generation = UUID()
    private enum Failure: Error { case unavailable }

    func prepare() throws {
        guard engine == nil else { return }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics,
              let url = Bundle.main.url(forResource: "OathSplash", withExtension: "ahap") else {
            throw Failure.unavailable
        }
        let engine = try CHHapticEngine()
        engine.playsHapticsOnly = true
        engine.isAutoShutdownEnabled = false
        let generation = self.generation
        // Invalidation is marshalled back to the main actor. A late callback
        // cannot resurrect an engine after the splash releases it.
        engine.resetHandler = { [weak self] in
            Task { @MainActor in self?.invalidate(generation: generation) }
        }
        engine.stoppedHandler = { [weak self] _ in
            Task { @MainActor in self?.invalidate(generation: generation) }
        }
        self.engine = engine
        try engine.start()
        player = try engine.makePlayer(with: CHHapticPattern(contentsOf: url))
    }

    func play() throws {
        guard let player else { throw Failure.unavailable }
        try player.start(atTime: CHHapticTimeImmediate)
        OathSplashDiagnostics.record("ahap-started")
    }

    func stop() {
        generation = UUID()
        engine?.resetHandler = {}
        engine?.stoppedHandler = { _ in }
        try? player?.stop(atTime: CHHapticTimeImmediate)
        engine?.stop(completionHandler: nil)
        player = nil
        engine = nil
    }

    private func invalidate(generation: UUID) {
        guard self.generation == generation else { return }
        stop()
    }
}

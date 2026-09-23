import CoreHaptics
import Foundation
import SwiftUI
import UIKit

/// The semantic vocabulary used by Aperture. Feature code describes meaning;
/// this layer alone decides how that meaning feels on the current device.
enum UniHaptic: Equatable, Sendable {
    case selection
    case selectionDeselect
    case tap
    case whisper
    case toggle
    case commit
    case warning
    case consequential
    case successQuiet
    case success
    case error
    case passcodeDigit
    case passcodeDelete
    case passcodeError
    case start
    case increase
    case decrease
    case levelChange
    case progressTick
    case onboardingDragTick
    case passcodeComplete
    case walletCreated
    case phraseReveal
    case transactionSigning
    case transactionSending
    case confirmation
}

enum UniHapticControlPolicy: Sendable {
    case automatic
    case silent
    case custom(UniHaptic)

    func resolved(automatic event: UniHaptic) -> UniHaptic? {
        switch self {
        case .automatic: event
        case .silent: nil
        case let .custom(event): event
        }
    }
}

@MainActor
final class UniHapticEngine {
    static let shared = UniHapticEngine()

    nonisolated static let preferenceKey = "settings.hapticFeedbackEnabled"

    private var coreEngine: CHHapticEngine?
    private let actionFeedback = UniHapticActionFeedback()
    private var preferenceIsEnabled = true
    private var isApplicationActive: () -> Bool = { UIApplication.shared.applicationState == .active }
    private var output: ((UniHaptic) -> Void)?
    private var lastErrorAt = Date.distantPast
    private var lastProgressAt = Date.distantPast
    private var lastOnboardingDragAt = Date.distantPast
    private lazy var selectionGenerator = UISelectionFeedbackGenerator()
    private lazy var softImpactGenerator =
        UIImpactFeedbackGenerator(style: .soft)
    private lazy var lightImpactGenerator =
        UIImpactFeedbackGenerator(style: .light)
    private lazy var mediumImpactGenerator =
        UIImpactFeedbackGenerator(style: .medium)
    private lazy var rigidImpactGenerator =
        UIImpactFeedbackGenerator(style: .rigid)
    private lazy var notificationGenerator =
        UINotificationFeedbackGenerator()

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                UniHapticEngine.shared.cancel()
            }
        }
    }

    /// Injectable platform boundary for deterministic feedback tests.
    init(isEnabled: Bool, isApplicationActive: @escaping () -> Bool,
         output: @escaping (UniHaptic) -> Void) {
        preferenceIsEnabled = isEnabled
        self.isApplicationActive = isApplicationActive
        self.output = output
    }

    var isEnabled: Bool {
        preferenceIsEnabled
    }

    func configure(isEnabled: Bool) {
        preferenceIsEnabled = isEnabled
        if !isEnabled {
            cancel()
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            preferenceIsEnabled = true
            play(.successQuiet, bypassPreference: true)
        } else {
            play(.whisper, bypassPreference: true)
            preferenceIsEnabled = false
            cancel()
        }
    }

    func play(_ event: UniHaptic) {
        play(event, bypassPreference: false)
    }

    func performAction(_ event: UniHaptic?, action: () -> Void) {
        actionFeedback.perform(fallback: event, emit: play, action: action)
    }

    func prepare(_ event: UniHaptic) {
        guard isEnabled else { return }
        guard isApplicationActive() else {
            return
        }
        prepareNative(event)
    }

    /// A chart tick whose strength follows the traversed price movement.
    func playMarketScrub(intensity: Double) {
        guard isEnabled, isApplicationActive(), intensity.isFinite else { return }
        actionFeedback.recordFeedback()
        if let output { output(.increase); return }
        rigidImpactGenerator.impactOccurred(intensity: min(1, max(0.45, intensity)))
        rigidImpactGenerator.prepare()
    }

    func prepareWalletActionControls() {
        guard isEnabled else { return }
        guard isApplicationActive() else {
            return
        }
        selectionGenerator.prepare()
        mediumImpactGenerator.prepare()
    }

    /// Exact intensities supplied with the Oath launch artwork, using the
    /// already-prepared shared generators rather than creating one per beat.
    func splashImpact(style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat) {
        guard permitsSplashFeedback else { return }
        switch style {
        case .soft: softImpactGenerator.impactOccurred(intensity: intensity)
        case .rigid: rigidImpactGenerator.impactOccurred(intensity: intensity)
        case .light: lightImpactGenerator.impactOccurred(intensity: intensity)
        default: break
        }
    }

    func cancel() {
        coreEngine?.stop()
        coreEngine = nil
    }

    private func play(_ event: UniHaptic, bypassPreference: Bool) {
        actionFeedback.recordFeedback()
        guard bypassPreference || isEnabled else { return }
        guard isApplicationActive() else { return }

        let now = Date()
        if event == .error || event == .passcodeError {
            guard now.timeIntervalSince(lastErrorAt) >= 0.65 else { return }
            lastErrorAt = now
        }
        if event == .progressTick {
            guard now.timeIntervalSince(lastProgressAt) >= 0.08 else { return }
            lastProgressAt = now
        }
        if event == .onboardingDragTick {
            guard now.timeIntervalSince(lastOnboardingDragAt) >= 0.045 else {
                return
            }
            lastOnboardingDragAt = now
        }

        if let output {
            output(event)
            return
        }

        if UIAccessibility.isReduceMotionEnabled || !isMilestone(event) {
            playNative(event)
        } else if !playCorePattern(event) {
            playNative(quietFallback(for: event))
        }
    }

    private func playNative(_ event: UniHaptic) {
        switch event {
        case .selection, .selectionDeselect, .levelChange, .progressTick:
            selectionGenerator.selectionChanged()
        case .tap, .whisper:
            softImpactGenerator.impactOccurred(
                intensity: event == .whisper ? 0.28 : 0.48
            )
        case .toggle, .successQuiet:
            lightImpactGenerator.impactOccurred(intensity: 0.62)
        case .onboardingDragTick:
            lightImpactGenerator.impactOccurred(intensity: 0.82)
        case .commit, .start, .increase, .decrease, .passcodeDelete:
            mediumImpactGenerator.impactOccurred(intensity: 0.72)
        case .passcodeDigit:
            rigidImpactGenerator.impactOccurred(intensity: 0.82)
        case .warning:
            notificationGenerator.notificationOccurred(.warning)
        case .consequential:
            rigidImpactGenerator.impactOccurred(intensity: 1)
        case .success, .passcodeComplete, .walletCreated, .phraseReveal,
             .transactionSigning, .transactionSending, .confirmation:
            notificationGenerator.notificationOccurred(.success)
        case .error:
            notificationGenerator.notificationOccurred(.error)
        case .passcodeError:
            notificationGenerator.notificationOccurred(.error)
            rigidImpactGenerator.impactOccurred(intensity: 1)
        }
        prepareNative(event)
    }

    private func prepareNative(_ event: UniHaptic) {
        switch event {
        case .selection, .selectionDeselect, .levelChange, .progressTick:
            selectionGenerator.prepare()
        case .tap, .whisper:
            softImpactGenerator.prepare()
        case .toggle, .successQuiet, .onboardingDragTick:
            lightImpactGenerator.prepare()
        case .commit, .start, .increase, .decrease, .passcodeDelete:
            mediumImpactGenerator.prepare()
        case .consequential, .passcodeDigit:
            rigidImpactGenerator.prepare()
        case .warning, .success, .error, .passcodeComplete,
             .walletCreated, .phraseReveal, .transactionSigning,
             .transactionSending, .confirmation:
            notificationGenerator.prepare()
        case .passcodeError:
            notificationGenerator.prepare()
            rigidImpactGenerator.prepare()
        }
    }

    private func playCorePattern(_ event: UniHaptic) -> Bool {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            return false
        }
        do {
            let engine = try activeCoreEngine()
            let specification = milestonePattern(event)
            let events = specification.enumerated().map { index, item in
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(
                            parameterID: .hapticIntensity,
                            value: item.intensity
                        ),
                        CHHapticEventParameter(
                            parameterID: .hapticSharpness,
                            value: item.sharpness
                        )
                    ],
                    relativeTime: Double(index) * item.delay
                )
            }
            let player = try engine.makePlayer(
                with: CHHapticPattern(events: events, parameters: [])
            )
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            coreEngine = nil
            return false
        }
    }

    private func activeCoreEngine() throws -> CHHapticEngine {
        if let coreEngine { return coreEngine }
        let engine = try CHHapticEngine()
        engine.isAutoShutdownEnabled = true
        engine.stoppedHandler = { _ in }
        engine.resetHandler = { [weak self] in
            Task { @MainActor in self?.coreEngine = nil }
        }
        try engine.start()
        coreEngine = engine
        return engine
    }

    private func isMilestone(_ event: UniHaptic) -> Bool {
        switch event {
        case .passcodeComplete, .passcodeError, .walletCreated, .phraseReveal,
             .transactionSigning, .transactionSending, .confirmation:
            true
        default:
            false
        }
    }

    private func quietFallback(for event: UniHaptic) -> UniHaptic {
        switch event {
        case .phraseReveal:
            .successQuiet
        case .passcodeError:
            .passcodeError
        default:
            .success
        }
    }

    private func milestonePattern(
        _ event: UniHaptic
    ) -> [(intensity: Float, sharpness: Float, delay: Double)] {
        switch event {
        case .passcodeError:
            [
                (1.00, 1.00, 0.07),
                (0.88, 0.82, 0.07),
                (1.00, 1.00, 0.07)
            ]
        case .passcodeComplete:
            [(0.62, 0.68, 0.07), (0.92, 0.86, 0.07)]
        case .walletCreated:
            [(0.34, 0.28, 0.09), (0.58, 0.48, 0.09), (0.90, 0.70, 0.09)]
        case .phraseReveal:
            [(0.26, 0.18, 0.12), (0.48, 0.32, 0.12)]
        case .transactionSigning:
            [(0.55, 0.76, 0.08), (0.78, 0.90, 0.08)]
        case .transactionSending:
            [(0.46, 0.42, 0.10), (0.72, 0.60, 0.10), (0.92, 0.82, 0.10)]
        default:
            [(0.44, 0.40, 0.09), (0.82, 0.72, 0.09)]
        }
    }
}

extension UniHaptic {
    @MainActor
    static func prepare(_ event: UniHaptic) {
        UniHapticEngine.shared.prepare(event)
    }

    @MainActor
    static func play(_ event: UniHaptic) {
        UniHapticEngine.shared.play(event)
    }

    @MainActor
    static func prepareWalletActionControls() {
        UniHapticEngine.shared.prepareWalletActionControls()
    }
}

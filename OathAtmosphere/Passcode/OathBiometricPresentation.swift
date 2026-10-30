import Foundation

/// Presentation bookkeeping only. This never authorizes a wallet operation.
/// Each credential store owns its instance so another scene's authentication
/// cannot remove this scene's privacy cover.
@MainActor final class OathBiometricPresentation {
    static let didChange = Notification.Name("OathBiometricPresentationDidChange")
    private var requests: Set<UUID> = []
    var isPresenting: Bool { !requests.isEmpty }

    nonisolated init() {}

    func begin() -> UUID {
        let id = UUID()
        requests.insert(id)
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return id
    }

    func end(_ id: UUID) {
        guard requests.remove(id) != nil else { return }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

/// An inactive scene can still be onscreen while our Face ID prompt finishes.
/// Keep the app-switcher cover for real departures, including departures during
/// authentication. Completion does not synthesize a foreground activation.
struct OathScenePrivacyPolicy {
    enum Phase { case active, inactive, background }
    private(set) var phase: Phase = .inactive
    private var biometricInterruption = false

    var needsCover: Bool {
        phase == .background || (phase == .inactive && !biometricInterruption)
    }

    mutating func transition(to phase: Phase, authenticating: Bool) {
        self.phase = phase
        biometricInterruption = phase == .inactive && authenticating
    }

    mutating func biometricPresentationChanged(isPresenting: Bool) {
        // Keep the exemption through the finishing animation. The next real
        // lifecycle transition resets it; a late reply cannot uncover background.
        if phase == .inactive && isPresenting { biometricInterruption = true }
    }
}

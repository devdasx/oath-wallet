import SwiftUI

struct WalletSecretScreenClock: Equatable, Sendable {
    private enum Source: Equatable, Sendable {
        case live
        case fixed(ContinuousClock.Instant)
    }

    private let source: Source
    private let identity: String

    init(
        identity: String,
        now: ContinuousClock.Instant? = nil
    ) {
        self.identity = identity
        self.source = now.map(Source.fixed) ?? .live
    }

    func now() -> ContinuousClock.Instant {
        switch source {
        case .live:
            .now
        case .fixed(let value):
            value
        }
    }

    static let live = WalletSecretScreenClock(
        identity: "wallet-secret-screen-live"
    )

    static func test(
        identity: String = UUID().uuidString,
        now: ContinuousClock.Instant = .now
    ) -> WalletSecretScreenClock {
        WalletSecretScreenClock(
            identity: identity,
            now: now
        )
    }

    static func == (lhs: WalletSecretScreenClock, rhs: WalletSecretScreenClock) -> Bool {
        lhs.identity == rhs.identity
    }
}

extension EnvironmentValues {
    /// Continuous time includes suspension; tests can advance it without waiting.
    @Entry var walletSecretScreenNow: WalletSecretScreenClock = .live
}

extension View {
    /// The screen owns its lifecycle. Only its secret destination is dismissed;
    /// the surrounding wallet, settings, and transaction navigation stays intact.
    func walletSecretScreenExpiry(
        lifecycle: Binding<WalletSensitiveContentLifecycleState>
    ) -> some View {
        modifier(WalletSecretScreenExpiryModifier(lifecycle: lifecycle))
    }
}

private struct WalletSecretScreenExpiryModifier: ViewModifier {
    @Binding var lifecycle: WalletSensitiveContentLifecycleState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.walletSecretScreenNow) private var now
    @Environment(\.walletAppLockIsPresented) private var isAppLockPresented
    @State private var isVisible = false
    @State private var isTrackingAbsence = false
    @State private var didRequestDismissal = false

    func body(content: Content) -> some View {
        content
            .walletCallSafetyWarning(.secret)
            .opacity(lifecycle.hasExpired ? 0 : 1)
            .allowsHitTesting(!lifecycle.hasExpired)
            .accessibilityHidden(lifecycle.hasExpired)
            .walletSensitiveContentMask(isProtected: lifecycle.isMasked,
                                       requiresProtection: lifecycle.isMasked || lifecycle.hasExpired)
            .onAppear {
                isVisible = true
                if scenePhase == .active {
                    dismissExpiredScreenIfVisible()
                } else {
                    protectVisibleScreen(for: scenePhase)
                }
            }
            .onDisappear { isVisible = false }
            .onChange(of: isAppLockPresented) { _, isLocked in
                if !isLocked, scenePhase == .active {
                    dismissExpiredScreenIfVisible()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    if isTrackingAbsence {
                        _ = lifecycle.resumeAfterInactive(now: now.now())
                        isTrackingAbsence = false
                    }
                    dismissExpiredScreenIfVisible()
                } else {
                    protectVisibleScreen(for: phase)
                }
            }
    }

    private func protectVisibleScreen(for phase: ScenePhase) {
        // NavigationStack retains previous destinations and delivers scene events
        // to them too. A recovery screen behind Success must never dismiss its
        // containing sheet. Keep tracking only the screen that was actually left.
        guard isVisible || isTrackingAbsence else { return }
        isTrackingAbsence = true
        _ = lifecycle.protect(
            for: phase == .background ? .sceneBackground : .sceneInactive,
            now: now.now()
        )
    }

    private func dismissExpiredScreenIfVisible() {
        // A native app-lock cover can still be on top when the scene activates.
        // Keep the secret masked and wait for this destination to reappear.
        guard isVisible, !isAppLockPresented,
              lifecycle.hasExpired, !didRequestDismissal else { return }
        didRequestDismissal = true
        dismiss()
    }
}

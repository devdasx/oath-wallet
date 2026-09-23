import Observation
import SwiftUI
import UIKit

/// Owns a scene-wide lock above the existing navigation hierarchy. It never
/// presents or dismisses a sheet, so locking cannot reset a destination or form.
@MainActor @Observable
final class WalletAppLockSceneController {
    enum Event { case inactive, background, foreground, active }

    private(set) var isLocked = false
    private(set) var scenePhase: ScenePhase = .active
    private(set) var hasStartedAuthentication = false
    private(set) var authenticationID = UUID()

    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var privacyShieldEnabled = false
    @ObservationIgnored private var timeout: Duration = .seconds(60)
    @ObservationIgnored private var backgroundedAt: ContinuousClock.Instant?
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    @ObservationIgnored private let notifications: NotificationCenter
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private weak var sourceWindow: UIWindow?
    @ObservationIgnored private weak var previousKeyWindow: UIWindow?
    @ObservationIgnored private var makeAuthenticationView: ((@escaping () -> Void) -> AnyView)?
    @ObservationIgnored private var onAuthenticated: (() -> Void)?
    @ObservationIgnored private var pendingAuthenticationID: UUID?
    @ObservationIgnored private var environment = EnvironmentValues()
    @ObservationIgnored private(set) var protectionWindow: UIWindow?

    init(
        now: @escaping () -> ContinuousClock.Instant = { .now },
        notifications: NotificationCenter = .default
    ) {
        self.now = now
        self.notifications = notifications
    }

    func configure(
        enabled: Bool,
        settings: WalletSecuritySettings,
        environment: EnvironmentValues = EnvironmentValues(),
        makeAuthenticationView: @escaping (@escaping () -> Void) -> AnyView,
        onAuthenticated: @escaping () -> Void
    ) {
        self.enabled = enabled && settings.requiresAuthentication
        privacyShieldEnabled = enabled && settings.privacyShieldEnabled
        timeout = .seconds(settings.autoLockDuration.seconds ?? 60)
        self.makeAuthenticationView = makeAuthenticationView
        self.onAuthenticated = onAuthenticated
        self.environment = environment
        if !self.enabled {
            setLocked(false)
        } else {
            requireLockIfExpired()
            updateWindow()
        }
    }

    func attach(to window: UIWindow) {
        guard sourceWindow !== window, let scene = window.windowScene else { return }
        removeWindow()
        removeObservers()
        sourceWindow = window
        switch scene.activationState {
        case .foregroundActive: scenePhase = .active
        case .background: scenePhase = .background
        default: scenePhase = .inactive
        }
        let events: [(Notification.Name, Event)] = [
            (UIScene.willDeactivateNotification, .inactive),
            (UIScene.didEnterBackgroundNotification, .background),
            (UIScene.willEnterForegroundNotification, .foreground),
            (UIScene.didActivateNotification, .active)
        ]
        for (name, event) in events {
            observers.append(notifications.addObserver(forName: name, object: scene, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.handle(event) }
            })
        }
        updateWindow()
    }

    func detach() {
        removeObservers()
        removeWindow()
        sourceWindow = nil
        makeAuthenticationView = nil
        onAuthenticated = nil
    }

    /// UIKit delivers these before SwiftUI's scenePhase update. Respect the
    /// switcher-privacy preference on exit, then install a required lock
    /// synchronously on foreground entry, before exposing the returning app.
    func handle(_ event: Event) {
        switch event {
        case .inactive:
            scenePhase = .inactive
        case .background:
            scenePhase = .background
            // Cancel the old challenge after a real departure, but not during
            // Face ID's own temporary inactive state.
            invalidateAuthentication()
            if backgroundedAt == nil { backgroundedAt = now() }
            requireLockIfExpired()
        case .foreground:
            scenePhase = .inactive
            requireLockIfExpired()
        case .active:
            requireLockIfExpired()
            scenePhase = .active
            if !isLocked { backgroundedAt = nil }
        }
        updateWindow()
        if case .active = event, let pendingAuthenticationID {
            authenticationSucceeded(requestID: pendingAuthenticationID)
        }
    }

    func requireLockIfExpired() {
        guard enabled, !isLocked, let backgroundedAt,
              backgroundedAt.duration(to: now()) >= timeout else { return }
        setLocked(true)
    }

    func setLocked(_ locked: Bool) {
        if isLocked != locked {
            isLocked = locked
            if !locked { invalidateAuthentication() }
        }
        if !locked {
            backgroundedAt = nil
        }
        updateWindow()
    }

    private func invalidateAuthentication() {
        hasStartedAuthentication = false
        authenticationID = UUID()
        pendingAuthenticationID = nil
    }

    fileprivate func authenticationContent() -> AnyView {
        let requestID = authenticationID
        return makeAuthenticationView? { [weak self] in
            self?.authenticationSucceeded(requestID: requestID)
        } ?? AnyView(AppBiometricPrivacyCover())
    }

    private func authenticationSucceeded(requestID: UUID) {
        // A late biometric/passcode result must not unlock a backgrounded app.
        guard enabled, isLocked, scenePhase != .background,
              requestID == authenticationID else { return }
        guard scenePhase == .active else {
            // UIKit may finish dismissing Face ID just before it delivers the
            // scene's activation. A real background event invalidates this ID.
            pendingAuthenticationID = requestID
            return
        }
        pendingAuthenticationID = nil
        onAuthenticated?()
    }

    private func updateWindow() {
        // App Lock controls access on return; it must not silently opt a user
        // into App Switcher Privacy. With privacy disabled the background
        // snapshot stays visible, even if the lock deadline has expired.
        let needsPrivacyCover = privacyShieldEnabled && scenePhase != .active
        let needsForegroundLock = enabled && isLocked && scenePhase != .background
        guard needsPrivacyCover || needsForegroundLock,
              let sourceWindow, let scene = sourceWindow.windowScene,
              makeAuthenticationView != nil else {
            removeWindow()
            return
        }
        if isLocked, scenePhase == .active { hasStartedAuthentication = true }
        if protectionWindow == nil {
            let host = UIHostingController(rootView: WalletAppLockWindowContent(
                controller: self
            ).environment(\.self, environment))
            host.view.backgroundColor = UIColor(WalletTheme.background)
            host.view.isOpaque = true
            host.view.accessibilityViewIsModal = true
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.frame = sourceWindow.frame
            window.backgroundColor = UIColor(WalletTheme.background)
            window.overrideUserInterfaceStyle = environment.colorScheme == .dark ? .dark : .light
            window.rootViewController = host
            protectionWindow = window
        }
        guard let window = protectionWindow else { return }
        UIView.performWithoutAnimation {
            window.frame = sourceWindow.frame
            window.isHidden = false
            if isLocked, scenePhase == .active, !window.isKeyWindow {
                previousKeyWindow = scene.keyWindow
                window.makeKey()
            }
            window.rootViewController?.view.layoutIfNeeded()
            window.layoutIfNeeded()
        }
    }

    private func removeWindow() {
        guard let window = protectionWindow else { return }
        let wasKey = window.isKeyWindow
        window.isHidden = true
        window.rootViewController = nil
        protectionWindow = nil
        if wasKey { (previousKeyWindow ?? sourceWindow)?.makeKey() }
        previousKeyWindow = nil
    }

    private func removeObservers() {
        observers.forEach { notifications.removeObserver($0) }
        observers.removeAll()
    }
}

private struct WalletAppLockWindowContent: View {
    let controller: WalletAppLockSceneController

    var body: some View {
        ZStack {
            WalletTheme.background.ignoresSafeArea()
            if controller.hasStartedAuthentication {
                controller.authenticationContent()
                    .id(controller.authenticationID)
            } else {
                AppBiometricPrivacyCover()
            }
        }
        .environment(\.scenePhase, controller.scenePhase)
        .environment(\.walletRootBackground, WalletTheme.background)
    }
}

/// Mount once at the app root; the native window also covers nested sheets and
/// UIKit presentations without issuing competing authentication requests.
struct WalletAppLockSceneBridge: UIViewRepresentable {
    let controller: WalletAppLockSceneController
    let database: WalletDatabase
    let settings: WalletSecuritySettings
    let enabled: Bool
    let onAuthenticated: () -> Void

    func makeCoordinator() -> WalletAppLockSceneController { controller }

    func makeUIView(context: Context) -> WalletAppLockAnchorView {
        configure(context)
        return WalletAppLockAnchorView { [weak controller] in controller?.attach(to: $0) }
    }

    func updateUIView(_ view: WalletAppLockAnchorView, context: Context) {
        configure(context)
        if let window = view.window { controller.attach(to: window) }
    }

    static func dismantleUIView(_ view: WalletAppLockAnchorView, coordinator: WalletAppLockSceneController) {
        coordinator.detach()
    }

    private func configure(_ context: Context) {
        controller.configure(enabled: enabled, settings: settings, environment: context.environment,
                             makeAuthenticationView: { completion in
            AnyView(WalletSecurityAuthenticationView(
                database: database, settings: settings, purpose: .appUnlock,
                onAuthenticated: completion
            )
            .walletLocalePresentation())
        }, onAuthenticated: onAuthenticated)
    }
}

final class WalletAppLockAnchorView: UIView {
    private let attached: (UIWindow) -> Void

    init(attached: @escaping (UIWindow) -> Void) {
        self.attached = attached
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // An ordinary full-screen presentation may temporarily detach the
        // underlying view. Keep scene protection until the root is dismantled.
        if let window { attached(window) }
    }
}

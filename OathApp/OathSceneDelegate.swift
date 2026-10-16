import SwiftUI
import Observation

/// One orientation policy for every scene and device family. Sheets and system
/// presentations must not widen the app's supported orientations.
enum OathInterfaceOrientation {
    static let supported: UIInterfaceOrientationMask = .portrait
}

/// Retained for installations that already saved the UIKit "Main" scene.
/// New scenes use WindowGroup; both paths share the same startup and lifecycle.
/// Changing the manifest alone does not replace a persisted scene delegate.
@MainActor
final class OathSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let context = OathSceneContext()

    @available(iOS 27.0, *)
    func supportedInterfaceOrientations(for windowScene: UIWindowScene) -> UIInterfaceOrientationMask {
        OathInterfaceOrientation.supported
    }

    func scene(_ scene: UIScene, willConnectTo sceneSession: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        OathWalletLinkInbox.shared.receive(connectionOptions)
        let window = UIWindow(windowScene: scene)
        self.window = window
        context.prepare(in: scene) { [weak self] in
            guard let self else { return }
            context.applyAppearance(to: window)
            let host = UIHostingController(rootView: OathSceneRoot(context: context))
            host.view.frame = window.bounds
            host.view.backgroundColor = OathSurfaceColors.canvas
            window.rootViewController = host
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            window.makeKeyAndVisible()
        }
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        contexts.first.map { OathWalletLinkInbox.shared.receive($0.url) }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        OathWalletLinkInbox.shared.receive(userActivity)
    }
}

/// SwiftUI forwards these callbacks through UIApplicationDelegateAdaptor and
/// injects this ObservableObject into the WindowGroup's environment, including
/// scenes created before this delegate was introduced. SwiftUI keeps ownership
/// of its window and hosting hierarchy, so trait changes preserve navigation.
@MainActor
final class OathSwiftUISceneDelegate: NSObject, UIWindowSceneDelegate, ObservableObject {
    fileprivate let context = OathSceneContext()

    @available(iOS 27.0, *)
    func supportedInterfaceOrientations(for windowScene: UIWindowScene) -> UIInterfaceOrientationMask {
        OathInterfaceOrientation.supported
    }

    func scene(_ scene: UIScene, willConnectTo sceneSession: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        OathWalletLinkInbox.shared.receive(connectionOptions)
        context.prepare(in: scene) { [weak self, weak scene] in
            guard let self, let scene else { return }
            for window in scene.windows {
                context.applyAppearance(to: window)
                window.rootViewController?.view.setNeedsLayout()
                window.rootViewController?.view.layoutIfNeeded()
            }
        }
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        contexts.first.map { OathWalletLinkInbox.shared.receive($0.url) }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        OathWalletLinkInbox.shared.receive(userActivity)
    }
}

struct OathSwiftUISceneRoot: View {
    @EnvironmentObject private var scene: OathSwiftUISceneDelegate

    var body: some View {
        Group {
            #if DEBUG && targetEnvironment(simulator)
            if OathWalletConnectRelayFixture.enabled {
                OathWalletConnectRelayFixture(session: scene.context.session)
                    .oathLanguage(OathLanguagePreference.current.resolve())
            } else if OathWalletConnectVisualFixture.enabled {
                OathWalletConnectVisualFixture()
                    .oathLanguage(OathLanguagePreference.current.resolve())
            } else {
                sceneRoot
            }
            #else
            sceneRoot
            #endif
        }
        .onOpenURL { OathWalletLinkInbox.shared.receive($0) }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { OathWalletLinkInbox.shared.receive($0) }
    }
    private var sceneRoot: some View {
        Group {
            if scene.context.ready {
                OathSceneRoot(context: scene.context)
            } else {
                // Keep link delivery alive while local launch reads finish.
                Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea()
            }
        }
    }
}

private extension OathWalletLinkInbox {
    func receive(_ options: UIScene.ConnectionOptions) {
        if let url = options.urlContexts.first?.url { receive(url) }
        else if let activity = options.userActivities.first(where: { $0.activityType == NSUserActivityTypeBrowsingWeb }) { receive(activity) }
    }

    func receive(_ activity: NSUserActivity) {
        guard activity.activityType == NSUserActivityTypeBrowsingWeb, let url = activity.webpageURL else { return }
        receive(url)
    }
}

/// UIKit keeps its launch surface until the first real screen is ready.
/// Local SQL/Keychain reads stay asynchronous; cloud/network work starts later.
/// Every scene owns one context, regardless of which launch version saved it.
@MainActor @Observable
private final class OathSceneContext {
    let session = OathWalletSession()
    let settings = OathAppSettings()
    private(set) var ready = false
    private(set) var phase: ScenePhase = .inactive
    @ObservationIgnored private let notifications = OathSceneNotifications()
    @ObservationIgnored private weak var scene: UIWindowScene?
    @ObservationIgnored private var connectionID = UUID()
    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private var privacyCover: OathAppSwitcherPrivacy?

    func prepare(in scene: UIWindowScene, onReady: @escaping @MainActor () -> Void) {
        guard self.scene !== scene else { return }
        startup?.cancel()
        notifications.removeAll()
        self.scene = scene
        let connectionID = UUID()
        self.connectionID = connectionID
        if scene.activationState != .background { session.enteringForeground() }
        switch scene.activationState {
        case .foregroundActive: phase = .active
        case .background: phase = .background
        default: phase = .inactive
        }
        observeLifecycle(of: scene)
        if ready { onReady(); return }
        // This API must be called during willConnect, not onAppear or while
        // attaching views. Balance it even on cancellation and read failure.
        // https://developer.apple.com/videos/play/wwdc2021/10057/?time=795
        scene.extendStateRestoration()
        startup = Task { [weak self] in
            defer { scene.completeStateRestoration() }
            guard let self else { return }
            async let preferences: Void = settings.loadInitial()
            async let wallet: Void = session.load()
            _ = await (preferences, wallet)
            guard !Task.isCancelled, self.connectionID == connectionID else { return }
            OathDiagnosticsRuntime.shared.launchReady()
            ready = true
            onReady()
            if phase != .active { showPrivacyCoverIfNeeded() }
            startup = nil
        }
    }

    func applyAppearance(to window: UIWindow) {
        switch settings.appearance {
        case .system: window.overrideUserInterfaceStyle = .unspecified
        case .light: window.overrideUserInterfaceStyle = .light
        case .dark: window.overrideUserInterfaceStyle = .dark
        }
        OathLayoutDirection.apply(settings.language, to: window)
    }

    private func observeLifecycle(of scene: UIWindowScene) {
        notifications.observe(UIScene.willEnterForegroundNotification, scene: scene) { [weak self] in
            guard let self else { return }
            session.enteringForeground()
            phase = .inactive
        }
        notifications.observe(UIScene.didActivateNotification, scene: scene) { [weak self] in
            guard let self else { return }
            phase = .active
            privacyCover?.removeFromSuperview()
            privacyCover = nil
        }
        notifications.observe(UIScene.willDeactivateNotification, scene: scene) { [weak self] in
            guard let self else { return }
            showPrivacyCoverIfNeeded()
            phase = .inactive
        }
        notifications.observe(UIScene.didEnterBackgroundNotification, scene: scene) { [weak self] in
            guard let self else { return }
            showPrivacyCoverIfNeeded()
            phase = .background
            session.enteredBackground(delay: settings.lockDelay)
        }
        notifications.observe(UIScene.didDisconnectNotification, scene: scene) { [weak self] in
            self?.disconnect()
        }
    }

    private func showPrivacyCoverIfNeeded() {
        guard settings.appSwitcherPrivacy,
              let window = scene?.keyWindow ?? scene?.windows.first else { return }
        let cover = privacyCover ?? OathAppSwitcherPrivacy(frame: window.bounds)
        privacyCover = cover
        if cover.superview !== window { window.addSubview(cover) }
        cover.updateAppearance()
        window.bringSubviewToFront(cover)
        cover.frame = window.bounds
        cover.layoutIfNeeded()
    }

    private func disconnect() {
        startup?.cancel()
        startup = nil
        connectionID = UUID()
        scene = nil
        notifications.removeAll()
        phase = .background
        // Disconnecting an interrupted fresh install must not manufacture a
        // passcode route for an empty vault.
        Task {
            guard phase == .background else { return }
            switch session.state {
            case .home, .locked: await session.lock(reason: .automatic)
            default: break
            }
        }
    }

    deinit { startup?.cancel() }
}

/// Deliver UIKit scene changes on MainActor, synchronously before snapshots.
/// The separate owner removes its observers safely even during deinit.
private final class OathSceneNotifications {
    private var tokens: [NSObjectProtocol] = []

    @MainActor
    func observe(_ name: Notification.Name, scene: UIScene, action: @escaping @MainActor () -> Void) {
        tokens.append(NotificationCenter.default.addObserver(forName: name, object: scene, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        })
    }

    func removeAll() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens.removeAll()
    }

    deinit { removeAll() }
}

private struct OathSceneRoot: View {
    let context: OathSceneContext

    var body: some View {
        OathLocalizedRoot(settings: context.settings) { OathWalletRoot(session: context.session) }
            .environment(\.scenePhase, context.phase)
    }
}

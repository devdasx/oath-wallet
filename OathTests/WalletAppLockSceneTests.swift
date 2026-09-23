import GRDB
import Observation
import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor @Suite(.serialized)
struct WalletAppLockSceneTests {
    @Test(arguments: WalletAutoLockDuration.allCases, [-0.001, 0.0, 0.001, 3_600.0])
    func timeoutIsCheckedBeforeForegroundActivation(
        duration: WalletAutoLockDuration, offset: Double
    ) throws {
        let clock = AppLockTestClock()
        let controller = WalletAppLockSceneController(now: { clock.instant })
        var settings = WalletSecuritySettings.secureDefault
        settings.autoLockDuration = duration
        controller.configure(enabled: true, settings: settings,
                             makeAuthenticationView: { _ in AnyView(Color.clear) }, onAuthenticated: {})
        controller.handle(.inactive)
        #expect(!controller.isLocked, "Face ID's inactive transition must not lock an unlocked app")
        controller.handle(.background)
        let elapsed = max(0, Double(try #require(duration.seconds)) + offset)
        clock.advance(elapsed)
        controller.handle(.foreground)
        #expect(controller.isLocked == (duration == .immediately || offset >= 0))
        #expect(controller.scenePhase == .inactive)
        #expect(!controller.hasStartedAuthentication, "Never start Face ID before the scene is active")
    }

    @Test
    func transientInactiveEventsAndSeparateShortAbsencesDoNotAccumulate() {
        let clock = AppLockTestClock()
        let controller = configuredController(clock: clock)
        controller.handle(.inactive)
        clock.advance(3_600)
        controller.handle(.active)
        #expect(!controller.isLocked)
        for _ in 0..<3 {
            controller.handle(.background)
            clock.advance(59)
            controller.handle(.foreground)
            controller.handle(.active)
            #expect(!controller.isLocked)
            clock.advance(100)
        }
    }

    @Test
    func repeatedBackgroundEventsCannotExtendDeadline() {
        let clock = AppLockTestClock()
        let controller = configuredController(clock: clock)
        controller.handle(.background)
        clock.advance(50)
        controller.handle(.background)
        clock.advance(10)
        controller.handle(.foreground)
        #expect(controller.isLocked)
        controller.handle(.active)
        #expect(controller.isLocked, "Activation cannot authorize access")
    }

    @Test(arguments: [false, true])
    func protectionRequiresAnEnabledWalletAndPasscode(walletEnabled: Bool) {
        let clock = AppLockTestClock()
        let controller = WalletAppLockSceneController(now: { clock.instant })
        var settings = WalletSecuritySettings.secureDefault
        settings.appLockEnabled = !walletEnabled
        controller.configure(enabled: walletEnabled, settings: settings,
                             makeAuthenticationView: { _ in AnyView(Color.clear) }, onAuthenticated: {})
        controller.handle(.background)
        clock.advance(10_000)
        controller.handle(.foreground)
        controller.handle(.active)
        #expect(!controller.isLocked)
        #expect(controller.protectionWindow == nil)
    }

    @Test(arguments: WalletAutoLockDuration.allCases, [false, true])
    func appSwitcherPrivacyIsIndependentOfAutoLock(
        duration: WalletAutoLockDuration, privacyEnabled: Bool
    ) async throws {
        let clock = AppLockTestClock()
        let notifications = NotificationCenter()
        let controller = WalletAppLockSceneController(now: { clock.instant }, notifications: notifications)
        let host = try NativeListTestHost { WalletTheme.background }
        defer { controller.detach(); host.close() }
        let source = try #require(host.rootView.window)
        let scene = try #require(source.windowScene)
        var settings = WalletSecuritySettings.secureDefault
        settings.autoLockDuration = duration
        settings.privacyShieldEnabled = privacyEnabled
        var unlocks = 0
        controller.configure(enabled: true, settings: settings, makeAuthenticationView: { completion in
            AnyView(AppLockTestAuthenticationButton(completion: completion))
        }, onAuthenticated: { unlocks += 1; controller.setLocked(false) })
        controller.attach(to: source)
        notifications.post(name: UIScene.didActivateNotification, object: scene)

        notifications.post(name: UIScene.willDeactivateNotification, object: scene)
        #expect((controller.protectionWindow != nil) == privacyEnabled)
        #expect(!controller.isLocked, "Opening the switcher must not itself lock the app")
        notifications.post(name: UIScene.didEnterBackgroundNotification, object: scene)
        #expect((controller.protectionWindow != nil) == privacyEnabled,
                "Even immediate auto-lock must respect the switcher preview preference")
        #expect(controller.isLocked == (duration == .immediately))

        clock.advance(Double(try #require(duration.seconds)))
        notifications.post(name: UIScene.willEnterForegroundNotification, object: scene)
        // No SwiftUI render or async work is allowed before this assertion:
        // the lock must already cover the returning app, with Privacy off too.
        let lockWindow = try #require(controller.protectionWindow)
        #expect(controller.isLocked)
        #expect(!lockWindow.isHidden)
        #expect(lockWindow.frame == source.frame)
        #expect(lockWindow.windowLevel > source.windowLevel)
        #expect(lockWindow.rootViewController?.view.isOpaque == true)
        #expect(!lockWindow.isKeyWindow)
        #expect(!controller.hasStartedAuthentication)
        #expect(unlocks == 0)
        notifications.post(name: UIScene.didActivateNotification, object: scene)
        try await settle { !SendEntryUIProbe.views(UIButton.self, in: lockWindow).isEmpty }
        #expect(lockWindow.isKeyWindow)
        #expect(controller.isLocked, "Privacy off must never bypass authentication")
        try await Task.sleep(for: .milliseconds(100))
        let button = try #require(SendEntryUIProbe.views(UIButton.self, in: lockWindow).first)
        button.sendActions(for: .touchUpInside)
        #expect(unlocks == 1)
        #expect(!controller.isLocked)
        #expect(controller.protectionWindow == nil)
        #expect(source.isKeyWindow)
    }

    @Test(arguments: [false, true])
    func privacyPreferenceUpdatesImmediatelyAndDoesNotRequirePasscode(appLockEnabled: Bool) async throws {
        let clock = AppLockTestClock()
        let controller = WalletAppLockSceneController(now: { clock.instant })
        let host = try NativeListTestHost { WalletTheme.background }
        defer { controller.detach(); host.close() }
        let source = try #require(host.rootView.window)
        var settings = WalletSecuritySettings.secureDefault
        settings.appLockEnabled = appLockEnabled
        func configure(walletEnabled: Bool = true) {
            controller.configure(enabled: walletEnabled, settings: settings,
                                 makeAuthenticationView: { _ in AnyView(Color.clear) }, onAuthenticated: {})
        }
        configure()
        controller.attach(to: source)
        controller.handle(.active)
        controller.handle(.inactive)
        #expect(controller.protectionWindow == nil)
        for _ in 0..<3 {
            settings.privacyShieldEnabled = true
            configure()
            let cover = try #require(controller.protectionWindow)
            #expect(!cover.isHidden)
            #expect(!cover.isKeyWindow)
            #expect(!controller.isLocked)
            settings.privacyShieldEnabled = false
            configure()
            #expect(controller.protectionWindow == nil)
            #expect(!controller.isLocked)
        }
        // A root with no open wallet must not leave a stray protection window.
        settings.privacyShieldEnabled = true
        configure(walletEnabled: false)
        #expect(controller.protectionWindow == nil)
    }

    @Test(arguments: NativeListTestLayout.allCases, [
        (fullScreen: false, privacyEnabled: false), (fullScreen: false, privacyEnabled: true),
        (fullScreen: true, privacyEnabled: false), (fullScreen: true, privacyEnabled: true)
    ])
    func lockImmediatelyCoversSheetsAndPreservesNavigationAndDraft(
        layout: NativeListTestLayout, presentation: (fullScreen: Bool, privacyEnabled: Bool)
    ) async throws {
        let (fullScreen, privacyEnabled) = presentation
        let clock = AppLockTestClock()
        let notifications = NotificationCenter()
        let controller = WalletAppLockSceneController(now: { clock.instant }, notifications: notifications)
        let state = AppLockResumeState()
        let host = try NativeListTestHost(layout: layout) {
            AppLockResumeHarness(state: state, fullScreen: fullScreen)
        }
        defer { controller.detach(); host.close() }
        let source = try #require(host.rootView.window)
        let scene = try #require(source.windowScene)
        try await settle { source.rootViewController?.presentedViewController?.viewIfLoaded?.window != nil }
        let sheet = try #require(source.rootViewController?.presentedViewController)
        try await settle { sheet.transitionCoordinator == nil && !sheet.isBeingPresented }
        state.path = [1]
        try await settle { !SendEntryUIProbe.views(UITextField.self, in: sheet.view).isEmpty }
        let field = try #require(SendEntryUIProbe.views(UITextField.self, in: sheet.view).first)
        field.text = "An unfinished wallet name"
        field.sendActions(for: .editingChanged)
        try await settle { state.draft == "An unfinished wallet name" }
        let appearances = state.appearances
        let disappearances = state.disappearances
        var environment = EnvironmentValues()
        environment.colorScheme = layout.colorScheme
        environment.layoutDirection = layout.direction
        environment.dynamicTypeSize = layout.textSize
        var settings = WalletSecuritySettings.secureDefault
        settings.privacyShieldEnabled = privacyEnabled
        controller.configure(enabled: true, settings: settings, environment: environment,
                             makeAuthenticationView: { completion in
            AnyView(AppLockTestAuthenticationButton(completion: completion))
        }, onAuthenticated: { controller.setLocked(false) })
        controller.attach(to: source)
        notifications.post(name: UIScene.didActivateNotification, object: scene)
        #expect(controller.protectionWindow == nil)

        for _ in 0..<3 {
            notifications.post(name: UIScene.willDeactivateNotification, object: scene)
            let privacyCover = controller.protectionWindow
            #expect((privacyCover != nil) == privacyEnabled)
            notifications.post(name: UIScene.didEnterBackgroundNotification, object: scene)
            #expect((controller.protectionWindow != nil) == privacyEnabled)
            clock.advance(60)
            notifications.post(name: UIScene.willEnterForegroundNotification, object: scene)
            let cover = try #require(controller.protectionWindow)
            // Assert synchronously, without letting SwiftUI render another frame.
            #expect(!cover.isHidden)
            #expect(cover.frame == source.frame)
            #expect(cover.windowLevel > source.windowLevel)
            #expect(cover.rootViewController?.view.isOpaque == true)
            #expect(cover.rootViewController?.view.backgroundColor?.cgColor.alpha == 1)
            #expect(!cover.isKeyWindow, "A privacy cover must not steal input from Apple's passkey/Face ID UI")
            #expect(controller.isLocked)
            if privacyEnabled { #expect(controller.protectionWindow === privacyCover) }
            #expect(!controller.hasStartedAuthentication)
            #expect(source.rootViewController?.presentedViewController === sheet)
            #expect(sheet.presentedViewController == nil, "Locking must not present an animated full-screen cover")
            #expect(cover.layer.animationKeys()?.isEmpty != false)
            notifications.post(name: UIScene.didActivateNotification, object: scene)
            try await settle { SendEntryUIProbe.views(UIButton.self, in: cover).first != nil }
            #expect(cover.isKeyWindow)
            #expect(cover.rootViewController?.transitionCoordinator == nil)
            #expect(cover.rootViewController?.view.accessibilityViewIsModal == true)
            // Let UIKit complete window appearance before simulating a person
            // authenticating; a view can mount before viewDidAppear runs.
            try await Task.sleep(for: .milliseconds(100))
            let button = try #require(SendEntryUIProbe.views(UIButton.self, in: cover).first)
            button.sendActions(for: .touchUpInside)
            #expect(!controller.isLocked)
            #expect(controller.protectionWindow == nil)
            #expect(source.isKeyWindow)
            try await Task.sleep(for: .milliseconds(100))
            #expect(source.rootViewController?.presentedViewController === sheet)
            #expect(state.path == [1])
            #expect(state.draft == "An unfinished wallet name")
            #expect(field.text == state.draft)
            #expect(state.appearances == appearances)
            #expect(state.disappearances == disappearances)
        }
    }

    @Test
    func lateAuthenticationCannotUnlockAfterLeavingOrDuringANewChallenge() async throws {
        let clock = AppLockTestClock()
        let controller = WalletAppLockSceneController(now: { clock.instant })
        let host = try NativeListTestHost { Color.clear }
        defer { controller.detach(); host.close() }
        var completions: [() -> Void] = []
        var unlocks = 0
        controller.configure(enabled: true, settings: .secureDefault, makeAuthenticationView: { completion in
            AnyView(AppLockTestAuthenticationButton(completion: completion)
                .onAppear { completions.append(completion) })
        }, onAuthenticated: { unlocks += 1; controller.setLocked(false) })
        controller.attach(to: try #require(host.rootView.window))
        controller.handle(.background)
        clock.advance(60)
        controller.handle(.foreground)
        controller.handle(.active)
        try await settle { completions.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        let staleCompletion = completions[0]
        controller.handle(.inactive)
        staleCompletion()
        #expect(controller.isLocked)
        #expect(unlocks == 0)
        controller.handle(.background)
        staleCompletion()
        #expect(controller.isLocked)
        #expect(unlocks == 0)
        controller.handle(.foreground)
        controller.handle(.active)
        try await settle { completions.count == 2 }
        staleCompletion()
        #expect(controller.isLocked)
        #expect(unlocks == 0)
        // Face ID's temporary inactive state keeps the current challenge intact.
        let authenticationID = controller.authenticationID
        controller.handle(.inactive)
        completions[1]()
        #expect(controller.isLocked)
        #expect(unlocks == 0)
        controller.handle(.active)
        #expect(controller.authenticationID != authenticationID)
        #expect(!controller.isLocked, "Resume the successful current challenge after Face ID dismisses")
        completions[1]()
        #expect(!controller.isLocked)
        #expect(unlocks == 1)
        completions[1]()
        #expect(unlocks == 1)
    }

    @Test(arguments: [NativeListTestLayout.phone, .largeTextRTL])
    func nativeBridgeDisplaysRealAuthenticationWithoutPresentingAModal(
        layout: NativeListTestLayout
    ) async throws {
        let database = try WalletDatabase.temporary()
        try await database.disableAppLock()
        try await database.enableAppLock(passcode: "739251")
        let reference = try #require(try await database.pool.read { db in
            try DBProfileSecurityRecord.fetchOne(db, key: WalletDatabase.defaultProfileID)?.passcodeKeychainReference
        })
        defer { try? WalletSecretVault.shared.deletePasscodeCredential(reference: reference) }
        let security = try await database.walletSecuritySettings()
        let previousLanguage = WalletRuntimePreferences.shared.languageIdentifier
        defer { WalletRuntimePreferences.shared.setLanguageIdentifier(previousLanguage) }
        var preferences = WalletApplicationSettings.default
        preferences.languageIdentifier = layout.direction == .rightToLeft ? "ar" : "en"
        let applicationSettings = WalletSettingsStore(database: database, initialSettings: preferences)
        let clock = AppLockTestClock()
        let controller = WalletAppLockSceneController(now: { clock.instant })
        let host = try NativeListTestHost(layout: layout) {
            WalletTheme.background
                .background {
                    WalletAppLockSceneBridge(controller: controller, database: database,
                        settings: security, enabled: true, onAuthenticated: { controller.setLocked(false) })
                    .frame(width: 0, height: 0)
                }
                .environment(applicationSettings)
        }
        defer { controller.detach(); host.close() }
        try await settle {
            host.rootView.layoutIfNeeded()
            return SendEntryUIProbe.views(WalletAppLockAnchorView.self, in: host.rootView)
                .contains { $0.window != nil }
        }
        controller.handle(.active)
        controller.handle(.background)
        clock.advance(60)
        controller.handle(.foreground)
        let window = try #require(controller.protectionWindow)
        controller.handle(.active)
        // The real view loads its policy from GRDB before showing the keypad.
        try await Task.sleep(for: .milliseconds(800))
        window.layoutIfNeeded()
        #expect(controller.isLocked)
        #expect(window.isKeyWindow)
        #expect(window.frame == host.rootView.window?.frame)
        #expect(window.overrideUserInterfaceStyle == (layout.colorScheme == .dark ? .dark : .light))
        #expect(host.rootView.window?.rootViewController?.presentedViewController == nil)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("instant-app-lock-\(layout).png")
        try image.pngData()?.write(to: url)
        print("App lock UI capture: \(url.path)")
        try await database.disableAppLock()
    }

    private func configuredController(clock: AppLockTestClock) -> WalletAppLockSceneController {
        let controller = WalletAppLockSceneController(now: { clock.instant })
        controller.configure(enabled: true, settings: .secureDefault,
                             makeAuthenticationView: { _ in AnyView(Color.clear) }, onAuthenticated: {})
        return controller
    }

    private func settle(_ ready: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<150 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(ready(), "Native app-lock UI did not settle", sourceLocation: sourceLocation)
    }
}

@MainActor
private final class AppLockTestClock {
    var instant = ContinuousClock.now
    func advance(_ seconds: Double) { instant = instant.advanced(by: .seconds(seconds)) }
}

@MainActor @Observable
private final class AppLockResumeState {
    var isPresented = true
    var path: [Int] = []
    var draft = ""
    var appearances = 0
    var disappearances = 0
}

private struct AppLockResumeHarness: View {
    @Bindable var state: AppLockResumeState
    let fullScreen: Bool

    var body: some View {
        if fullScreen {
            Color.clear.fullScreenCover(isPresented: $state.isPresented) { navigation }
        } else {
            Color.clear.sheet(isPresented: $state.isPresented) { navigation }
        }
    }

    private var navigation: some View {
        NavigationStack(path: $state.path) {
            Text(verbatim: "Settings fixture")
                .navigationDestination(for: Int.self) { _ in
                    TextField("Draft", text: $state.draft)
                        .onAppear { state.appearances += 1 }
                        .onDisappear { state.disappearances += 1 }
                }
        }
    }
}

/// This fixture tests window handoff only; production still requires the real
/// WalletSecurityAuthenticationView and its database-backed authentication.
private struct AppLockTestAuthenticationButton: UIViewRepresentable {
    let completion: () -> Void

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle("Authentication fixture", for: .normal)
        button.addAction(UIAction { _ in completion() }, for: .touchUpInside)
        return button
    }

    func updateUIView(_ view: UIButton, context: Context) {}
}

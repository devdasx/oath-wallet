import OathDiagnostics
import SwiftUI
import OathNativeLock

@main
struct OathAtmosphereApp: App {
    init() { OathDiagnosticsRuntime.shared.start() }
    @UIApplicationDelegateAdaptor(OathApplicationDelegate.self) private var delegate

    // Existing installations can restore a WindowGroup's AppSceneDelegate.
    // It requires the AppGraph created by App.main(). The scene delegate still
    // gates the first frame on local wallet/settings readiness.
    var body: some Scene {
        WindowGroup {
            OathSwiftUISceneRoot()
        }
    }
}

final class OathApplicationDelegate: NSObject, UIApplicationDelegate {
    // The scene delegate owns this policy on iOS 27. Retain the app callback
    // for earlier systems, including UIKit presentations above SwiftUI content.
    @available(iOS, introduced: 6.0, deprecated: 27.0, message: "Use the shared scene orientation policy on iOS 27.")
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OathInterfaceOrientation.supported
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        OathSendStatusTracking.shared.register()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        if session.role == .windowApplication {
            configuration.delegateClass = OathSwiftUISceneDelegate.self
        }
        return configuration
    }
}

struct OathWalletRoot: View {
    let session: OathWalletSession
    @State private var showsInitialLock: Bool
    @State private var lockIsVisible = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.oathLocalizer) private var strings
    @Environment(OathAppSettings.self) private var settings

    init(session: OathWalletSession) {
        self.session = session
        _showsInitialLock = State(initialValue: session.isLocked)
    }

    var body: some View {
        ZStack {
            if session.resetting {
                OathResetProgressPage(session: session)
            } else if session.isUpgrading {
                OathLegacyUpgradeScreen(session: session)
            } else if session.presentsOnboarding {
                OathOnboardingFlow(session: session)
                    .disabled(session.isLocked)
                    .accessibilityHidden(session.isLocked)
            } else if session.displayedProfile != nil || session.isLocked || session.isUnlocked {
                // This branch stays at the same structural identity while
                // locked. Presented sheets, navigation and scroll stay intact.
                OathHomeScreen(profile: session.displayedProfile, session: session)
                    .disabled(session.isLocked)
                    .accessibilityHidden(session.isLocked || showsInitialLock)
                    // Cold launch mounts the cover in the same view hierarchy
                    // and frame. Later locks present above the retained sheets.
                    .opacity(scenePhase != .background && session.isLocked && !showsInitialLock && !lockIsVisible ? 0 : 1)
            } else {
                switch session.state {
                case .loading: Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea()
                case .upgrading, .onboarding, .locked, .home:
                    Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea()
                case .unavailable:
                    OathEmptyStateScrollView {
                        OathEmptyState(title: strings.text(.walletUnavailable), systemImage: "lock.shield") {
                            OathActionButton(title: strings.text(.tryAgain), appearance: .secondary) {
                                session.state = .loading
                                Task { await session.load() }
                            }
                            .oathActionArea()
                        }
                    }
                }
            }
        }
        .overlay {
            if showsInitialLock {
                NativeInitialLock(isLocked: session.isLocked, onUnlocked: { showsInitialLock = false }) { visible in
                    OathWalletUnlockScreen(session: session, isVisible: visible)
                        .environment(\.oathLanguage, strings.language)
                }
                .ignoresSafeArea()
            }
        }
        .background {
            NativeLockPresentation(isLocked: session.isLocked && !showsInitialLock &&
                                   (scenePhase != .background || lockIsVisible)) { visible in
                OathWalletUnlockScreen(session: session, isVisible: visible)
                    .environment(\.oathLanguage, strings.language)
                    .onChange(of: visible, initial: true) { _, value in lockIsVisible = value }
            }
        }
        .statusBarHidden(false)
        .task(id: scenePhase) {
            if scenePhase == .active { await settings.refreshAppIcon() }
        }
        .task {
            // The scene already resolved the local route. Cloud resumption is
            // deliberately outside the first-screen readiness boundary.
            guard session.allowsBackgroundWalletWork else { return }
            async let cloudResume: Void? = await OathDiagnostics.attempt("backup_resume") { try await OathCloudBackupService.shared.resume() }
            async let rates = await OathDiagnostics.attempt("exchange_rates") { try await OathExchangeRateEnvironment.shared.refresh() }
            _ = await cloudResume
            _ = await rates
        }
        .onChange(of: session.isUnlocked) { _, unlocked in
            // Setup may finish opening SQL metadata after its foreground Face
            // ID success, during a real background transition. Do not leave a
            // newly opened session unlocked because the scene event came first.
            guard unlocked, scenePhase == .background else { return }
            session.enteredBackground(delay: settings.lockDelay)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    guard session.allowsBackgroundWalletWork else { return }
                    async let cloudResume: Void? = await OathDiagnostics.attempt("backup_resume") { try await OathCloudBackupService.shared.resume() }
                    async let rates = await OathDiagnostics.attempt("exchange_rates") { try await OathExchangeRateEnvironment.shared.refresh() }
                    _ = await cloudResume
                    _ = await rates
                }
            }
        }
        .onChange(of: session.security.passcodeEnabled) { _, enabled in
            if enabled, scenePhase == .background { session.enteredBackground(delay: settings.lockDelay) }
        }
    }
}

private struct OathOnboardingFlow: View {
    @Environment(\.oathLanguage) private var language
    let session: OathWalletSession
    private enum Destination: Hashable {
        case passcode, chooseChain, recoveryPhrase, importPasscode, customize(String)
        case privateKey(OathPrivateKeyChoice), privateKeyPasscode, restorePasscode
    }
    @State private var path: [Destination] = []
    @State private var showsMoreOptions = false
    @State private var pendingDestination: Destination?
    @State private var pendingPrivateKey: OathImportedPrivateKey?
    @State private var pendingRestore: OathRestoredWallet?
    @State private var recoveryDraft = OathRecoveryPhraseDraft()
    // Passed straight to the encrypted vault after confirmation, never stored
    // in NavigationPath, preferences, state restoration, or diagnostic output.
    @State private var pendingRecoveryPhrase: OathValidatedMnemonic?

    var body: some View {
        NavigationStack(path: $path) {
            OathOnboardingScreen(
                onCreateWallet: { path.append(.passcode) },
                onImportWallet: { path.append(.recoveryPhrase) },
                onMoreOptions: { showsMoreOptions = true }
            )
            .oathNativeLocalization(onArtwork: true, navigationBackground: .hidden)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .passcode:
                    passcodeScreen(importing: nil)
                        .toolbar(.visible, for: .navigationBar)
                case .chooseChain:
                    OathChooseChainScreen { path.append(.privateKey($0)) }
                        .toolbar(.visible, for: .navigationBar)
                case .privateKey(let choice):
                    OathPrivateKeyImportScreen(choice: choice) { key, _ in
                        guard path.last == .privateKey(choice) else { return }
                        pendingPrivateKey = key
                        path.append(.privateKeyPasscode)
                    }
                    .toolbar(.visible, for: .navigationBar)
                case .privateKeyPasscode:
                    passcodeScreen(importing: nil, privateKey: pendingPrivateKey)
                        .toolbar(.visible, for: .navigationBar)
                case .restorePasscode:
                    if let pendingRestore {
                        restoredPasscodeScreen(pendingRestore)
                            .toolbar(.visible, for: .navigationBar)
                    }
                case .recoveryPhrase:
                    OathRecoveryPhraseScreen(draft: recoveryDraft) { phrase in
                        guard path.last == .recoveryPhrase else { return }
                        pendingRecoveryPhrase = phrase
                        path.append(.importPasscode)
                    }
                    .toolbar(.visible, for: .navigationBar)
                case .importPasscode:
                    // Keep the completed source screen alive during the native
                    // push, even after the import draft has been cleared.
                    passcodeScreen(importing: pendingRecoveryPhrase)
                        .toolbar(.visible, for: .navigationBar)
                case .customize(let id):
                    OathWalletCustomizationScreen(session: session, walletID: id, mode: .setup) {
                        session.finishInitialCustomization()
                    }
                    .oathWalletCustomizationNavigation()
                    // The vault and app lock are already committed. Back must
                    // never return to PIN setup or create another first wallet.
                    .navigationBarBackButtonHidden()
                }
            }
        }
        .sheet(isPresented: $showsMoreOptions, onDismiss: openPendingDestination) {
            OathMoreOptionsSheet(onImportPrivateKey: {
                pendingDestination = .chooseChain
                showsMoreOptions = false
            }, onRestore: { restored in
                pendingRestore = restored
                pendingDestination = .restorePasscode
                showsMoreOptions = false
            })
            .oathLanguage(language)
        }
        // Preserve the native status bar throughout navigation and sheet presentation.
        .statusBarHidden(false)
        .onChange(of: path) { _, destinations in
            if !destinations.contains(.importPasscode) { pendingRecoveryPhrase = nil }
            if !destinations.contains(.privateKeyPasscode) { pendingPrivateKey = nil }
            if !destinations.contains(.restorePasscode) { pendingRestore = nil }
            if !destinations.contains(.recoveryPhrase) { recoveryDraft.clear() }
        }
        .onChange(of: session.isUnlocked) { _, unlocked in
            if unlocked { showCustomization() }
        }
    }

    private func passcodeScreen(importing phrase: OathValidatedMnemonic?, privateKey: OathImportedPrivateKey? = nil) -> some View {
        let vault = session.vault
        return OathPasscodeSetupScreen(
            store: OathWalletSetupStore(vault: vault, phrase: phrase, privateKey: privateKey),
            biometrics: OathDeviceBiometrics(credentialStore: vault.biometricStore,
                                            credentialProvider: { try await vault.biometricCredential() })
        ) {
            Task {
                await session.finishedSetup()
                pendingRecoveryPhrase = nil
                pendingPrivateKey = nil
                recoveryDraft.clear()
                showCustomization()
            }
        }
    }

    private func restoredPasscodeScreen(_ restoration: OathRestoredWallet) -> some View {
        let vault = session.vault
        return OathPasscodeSetupScreen(
            store: OathRestoredWalletSetupStore(vault: vault, restoration: restoration),
            biometrics: OathDeviceBiometrics(credentialStore: vault.biometricStore,
                                            credentialProvider: { try await vault.biometricCredential() })
        ) {
            Task {
                await session.finishedSetup(requiresCustomization: false)
                pendingRestore = nil
            }
        }
    }

    private func showCustomization() {
        guard session.isUnlocked, let id = session.pendingCustomizationID,
              !path.contains(.customize(id)) else { return }
        path.append(.customize(id))
    }

    private func openPendingDestination() {
        guard let destination = pendingDestination else { return }
        pendingDestination = nil
        path.append(destination)
    }
}

import OathDiagnostics
import SwiftUI
import OathCloudBackup
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
            } else if session.displayedProfile != nil || session.isUnlocked {
                // This branch stays at the same structural identity while
                // locked. Presented sheets, navigation and scroll stay intact.
                // A cold lock with no wallet snapshot uses the blank surface
                // beneath the lock cover, never a fabricated empty Home.
                OathHomeScreen(profile: session.displayedProfile, session: session, settings: settings)
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
                NativeInitialLock(isLocked: session.isLocked, animatesUnlock: session.animatesUnlock,
                                  onUnlocked: { showsInitialLock = false }) { visible in
                    OathWalletUnlockScreen(session: session, isVisible: visible)
                        .environment(\.oathLanguage, strings.language)
                }
                .ignoresSafeArea()
            }
        }
        .background {
            NativeLockPresentation(isLocked: session.isLocked && !showsInitialLock &&
                                   (scenePhase != .background || lockIsVisible),
                                   animatesUnlock: session.animatesUnlock) { visible in
                OathWalletUnlockScreen(session: session, isVisible: visible)
                    .environment(\.oathLanguage, strings.language)
                    .onChange(of: visible, initial: true) { _, value in lockIsVisible = value }
            }
        }
        .statusBarHidden(false)
        .task(id: scenePhase) {
            OathDiagnostics.setLifecycle(scenePhase == .active ? .active : (scenePhase == .background ? .background : .inactive))
            if scenePhase == .active {
                await settings.refreshAppIcon()
                // Import drafts can exist before the first wallet does. Resume
                // their durable queue on welcome too, without starting portfolio
                // services or bypassing a reset/legacy-upgrade boundary.
                if !session.resetting && (session.presentsOnboarding || session.allowsBackgroundWalletWork) {
                }
            }
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
            OathDiagnostics.setLifecycle(phase == .active ? .active : (phase == .background ? .background : .inactive))
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
        .onChange(of: session.resetting) { _, resetting in
            if resetting {
                OathVaultImportInbox.shared.clear()
                OathWalletLinkInbox.shared.clear()
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
        case multisigChains, evmMultisigChains, multisigSetup, multisigPasscode
        case privateKey(OathPrivateKeyChoice), privateKeyPasscode, restorePasscode
    }
    @State private var path: [Destination] = []
    @State private var showsMoreOptions = false
    @State private var pendingDestination: Destination?
    @State private var multisigDraft = OathMultisigDraft()
    @State private var pendingMultisig: BackupWallet.BitcoinMultisig?
    @State private var pendingEVMMultisig: BackupWallet.EVMMultisig?
    @State private var pendingTonMultisig: BackupWallet.TonMultisig?
    @State private var pendingThorchainMultisig: BackupWallet.ThorchainMultisig?
    @State private var pendingNearMultisig: BackupWallet.NearMultisig?
    @State private var pendingSuiMultisig: BackupWallet.SuiMultisig?
    @State private var pendingAptosMultisig: BackupWallet.AptosMultisig?
    @State private var pendingStellarMultisig: BackupWallet.StellarMultisig?
    @State private var pendingXrplMultisig: BackupWallet.XrplMultisig?
    @State private var pendingSolanaMultisig: BackupWallet.SolanaMultisig?
    @State private var pendingTronMultisig: BackupWallet.TronMultisig?
    @State private var pendingPrivateKey: OathImportedPrivateKey?
    @State private var pendingRestore: OathRestoredWallet?
    @State private var recoveryDraft = OathRecoveryPhraseDraft()
    // Passed straight to the encrypted vault after confirmation, never stored
    // in NavigationPath, preferences, state restoration, or diagnostic output.
    @State private var pendingRecoveryPhrase: OathValidatedMnemonic?
    @State private var retainedFlow: OathAdditionalWalletDestination?
    @State private var pendingRetainedFlow: OathAdditionalWalletDestination?
    @State private var retainedCreateID = UUID()
    @State private var retainedCreationFailed = false

    var body: some View {
        NavigationStack(path: $path) {
            OathOnboardingScreen(
                onCreateWallet: {
                    if session.welcomesWithRetainedWallets {
                        guard !session.changingWallet else { return }
                        Task {
                            do { retainedFlow = .customize(try await session.addWallet(requestID: retainedCreateID)) }
                            catch { OathDiagnostics.record(error, component: "wallet_lifecycle", operation: "create_after_remote_removal"); retainedCreationFailed = true }
                        }
                    } else { path.append(.passcode) }
                },
                onImportWallet: {
                    if session.welcomesWithRetainedWallets { retainedFlow = .importPhrase }
                    else { path.append(.recoveryPhrase) }
                },
                onMoreOptions: { showsMoreOptions = true }
            )
            .oathNativeLocalization(navigationBackground: .hidden, navigationMaterial: nil, systemNavigationAppearance: true)
            .modifier(OathArtworkNavigationAppearance())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .multisigChains:
                    OathMultisigChainScreen(onBitcoin: {
                        multisigDraft.clear(); multisigDraft.chain = .bitcoin; path.append(.multisigSetup)
                    }, onLitecoin: {
                        multisigDraft.clear(); multisigDraft.chain = .litecoin; path.append(.multisigSetup)
                    }, onDogecoin: {
                        multisigDraft.clear(); multisigDraft.chain = .dogecoin; path.append(.multisigSetup)
                    }, onBitcoinCash: {
                        multisigDraft.clear(); multisigDraft.chain = .bitcoincash; path.append(.multisigSetup)
                    }, onTron: {
                        multisigDraft.clear(); multisigDraft.chain = .tron; path.append(.multisigSetup)
                    }, onSolana: {
                        multisigDraft.clear(); multisigDraft.chain = .solana; path.append(.multisigSetup)
                    }, onEVM: {
                        path.append(.evmMultisigChains)
                    }, onTon: {
                        multisigDraft.clear(); multisigDraft.chain = .ton; path.append(.multisigSetup)
                    }, onThorchain: {
                        multisigDraft.clear(); multisigDraft.chain = .thorchain; path.append(.multisigSetup)
                    }, onNear: {
                        multisigDraft.clear(); multisigDraft.chain = .near; path.append(.multisigSetup)
                    }, onSui: {
                        multisigDraft.clear(); multisigDraft.chain = .sui; path.append(.multisigSetup)
                    }, onAptos: {
                        multisigDraft.clear(); multisigDraft.chain = .aptos; path.append(.multisigSetup)
                    }, onStellar: {
                        multisigDraft.clear(); multisigDraft.chain = .stellar; path.append(.multisigSetup)
                    }, onXrpl: {
                        multisigDraft.clear(); multisigDraft.chain = .xrpl; path.append(.multisigSetup)
                    })
                        .toolbar(.visible, for: .navigationBar)
                case .evmMultisigChains:
                    OathEVMMultisigNetworkScreen { network in
                        multisigDraft.clear(); multisigDraft.chain = .evm; multisigDraft.evmNetwork = network
                        path.append(.multisigSetup)
                    }.toolbar(.visible, for: .navigationBar)
                case .multisigSetup:
                    OathMultisigSetupScreen(draft: multisigDraft, onReady: { material in
                        guard path.last == .multisigSetup else { return }
                        pendingMultisig = material
                        path.append(.multisigPasscode)
                    }, onTronReady: { material in
                        guard path.last == .multisigSetup else { return }
                        pendingTronMultisig = material
                        path.append(.multisigPasscode)
                    }, onEVMReady: { material in
                        guard path.last == .multisigSetup else { return }
                        pendingEVMMultisig = material
                        path.append(.multisigPasscode)
                    }, onTonReady: { material in
                        guard path.last == .multisigSetup else { return }
                        pendingTonMultisig = material
                        path.append(.multisigPasscode)
                    }, onThorchainReady: { material in
                        guard path.last == .multisigSetup else { return }
                        pendingThorchainMultisig = material
                        path.append(.multisigPasscode)
                    }, onNearReady: { material in
                        guard path.last == .multisigSetup else { return }
                        pendingNearMultisig = material
                        path.append(.multisigPasscode)
                    }, onSuiReady: { material in
                        guard path.last == .multisigSetup else { return }
                        pendingSuiMultisig = material
                        path.append(.multisigPasscode)
                    }, onAptosReady: { material in
                        guard path.last == .multisigSetup else { return }
                        pendingAptosMultisig = material
                        path.append(.multisigPasscode)
                    }, onStellarReady: { material in
                        guard path.last == .multisigSetup else { return }
                        pendingStellarMultisig = material
                        path.append(.multisigPasscode)
                    }, onXrplReady: { material in
                        guard path.last == .multisigSetup else { return }
                        pendingXrplMultisig = material
                        path.append(.multisigPasscode)
                    }, onSolanaReady: { material in
                        guard path.last == .multisigSetup else { return }
                        pendingSolanaMultisig = material
                        path.append(.multisigPasscode)
                    })
                    .toolbar(.visible, for: .navigationBar)
                case .multisigPasscode:
                    if let pendingMultisig {
                        passcodeScreen(importing: nil, multisig: pendingMultisig)
                            .toolbar(.visible, for: .navigationBar)
                    } else if let pendingEVMMultisig {
                        passcodeScreen(importing: nil, evmMultisig: pendingEVMMultisig)
                            .toolbar(.visible, for: .navigationBar)
                    } else if let pendingTonMultisig {
                        passcodeScreen(importing: nil, tonMultisig: pendingTonMultisig)
                            .toolbar(.visible, for: .navigationBar)
                    } else if let pendingThorchainMultisig {
                        passcodeScreen(importing: nil, thorchainMultisig: pendingThorchainMultisig)
                            .toolbar(.visible, for: .navigationBar)
                    } else if let pendingNearMultisig {
                        passcodeScreen(importing: nil, nearMultisig: pendingNearMultisig)
                    } else if let pendingSuiMultisig {
                        passcodeScreen(importing: nil, suiMultisig: pendingSuiMultisig)
                    } else if let pendingAptosMultisig {
                        passcodeScreen(importing: nil, aptosMultisig: pendingAptosMultisig)
                            .toolbar(.visible, for: .navigationBar)
                    } else if let pendingStellarMultisig {
                        passcodeScreen(importing: nil, stellarMultisig: pendingStellarMultisig)
                            .toolbar(.visible, for: .navigationBar)
                    } else if let pendingXrplMultisig {
                        passcodeScreen(importing: nil, xrplMultisig: pendingXrplMultisig)
                            .toolbar(.visible, for: .navigationBar)
                    } else if let pendingSolanaMultisig {
                        passcodeScreen(importing: nil, solanaMultisig: pendingSolanaMultisig)
                            .toolbar(.visible, for: .navigationBar)
                    } else if let pendingTronMultisig {
                        passcodeScreen(importing: nil, tronMultisig: pendingTronMultisig)
                            .toolbar(.visible, for: .navigationBar)
                    }
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
        .oathVaultImport(session: session, canPresent: path.isEmpty && !showsMoreOptions)
        .sheet(item: $retainedFlow, onDismiss: { session.finishInitialCustomization() }) { destination in
            OathAdditionalWalletFlow(session: session, start: destination).oathLanguage(language)
        }
        .alert(OathLocalizer(language).text(.walletChangeFailed), isPresented: $retainedCreationFailed) {
            Button(OathLocalizer(language).text(.cancel), role: .cancel) {}
        }
        .sheet(isPresented: $showsMoreOptions, onDismiss: openPendingDestination) {
            OathMoreOptionsSheet(onImportPrivateKey: {
                if session.welcomesWithRetainedWallets { pendingRetainedFlow = .importPrivateKey }
                else { pendingDestination = .chooseChain }
                showsMoreOptions = false
            }, onCreateMultisigWallet: {
                if session.welcomesWithRetainedWallets { pendingRetainedFlow = .createMultisig }
                else { pendingDestination = .multisigChains }
                showsMoreOptions = false
            }, onRestore: { restored in
                pendingRestore = restored
                if !session.welcomesWithRetainedWallets { pendingDestination = .restorePasscode }
                showsMoreOptions = false
            })
            .oathLanguage(language)
        }
        // Preserve the native status bar throughout navigation and sheet presentation.
        .statusBarHidden(false)
        .onChange(of: path) { _, destinations in
            if !destinations.contains(.multisigPasscode) { pendingMultisig = nil; pendingTronMultisig = nil; pendingSolanaMultisig = nil; pendingXrplMultisig = nil; pendingStellarMultisig = nil; pendingAptosMultisig = nil; pendingSuiMultisig = nil; pendingEVMMultisig = nil; pendingTonMultisig = nil; pendingThorchainMultisig = nil; pendingNearMultisig = nil }
            if !destinations.contains(.multisigSetup) { multisigDraft.clear() }
            if !destinations.contains(.importPasscode) { pendingRecoveryPhrase = nil }
            if !destinations.contains(.privateKeyPasscode) { pendingPrivateKey = nil }
            if !destinations.contains(.restorePasscode) { pendingRestore = nil }
            if !destinations.contains(.recoveryPhrase) { recoveryDraft.clear() }
        }
        .onChange(of: session.isUnlocked) { _, unlocked in
            if unlocked { showCustomization() }
        }
    }

    private func passcodeScreen(importing phrase: OathValidatedMnemonic?, privateKey: OathImportedPrivateKey? = nil, multisig: BackupWallet.BitcoinMultisig? = nil, tronMultisig: BackupWallet.TronMultisig? = nil, solanaMultisig: BackupWallet.SolanaMultisig? = nil, xrplMultisig: BackupWallet.XrplMultisig? = nil, stellarMultisig: BackupWallet.StellarMultisig? = nil, aptosMultisig: BackupWallet.AptosMultisig? = nil, suiMultisig: BackupWallet.SuiMultisig? = nil, nearMultisig: BackupWallet.NearMultisig? = nil, evmMultisig: BackupWallet.EVMMultisig? = nil, tonMultisig: BackupWallet.TonMultisig? = nil, thorchainMultisig: BackupWallet.ThorchainMultisig? = nil) -> some View {
        let vault = session.vault
        return OathPasscodeSetupScreen(
            store: OathWalletSetupStore(vault: vault, phrase: phrase, privateKey: privateKey, multisig: multisig, solanaMultisig: solanaMultisig, evmMultisig: evmMultisig, tonMultisig: tonMultisig, thorchainMultisig: thorchainMultisig, nearMultisig: nearMultisig, suiMultisig: suiMultisig, aptosMultisig: aptosMultisig, stellarMultisig: stellarMultisig, xrplMultisig: xrplMultisig, tronMultisig: tronMultisig),
            biometrics: OathDeviceBiometrics(credentialStore: vault.biometricStore,
                                            credentialProvider: { try await vault.biometricCredential() })
        ) {
            Task {
                await session.finishedSetup()
                pendingMultisig = nil; pendingTronMultisig = nil; pendingSolanaMultisig = nil; pendingXrplMultisig = nil; pendingStellarMultisig = nil; pendingAptosMultisig = nil; pendingSuiMultisig = nil; pendingEVMMultisig = nil; pendingTonMultisig = nil; pendingThorchainMultisig = nil; pendingNearMultisig = nil
                multisigDraft.clear()
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
        if let flow = pendingRetainedFlow {
            pendingRetainedFlow = nil; retainedFlow = flow; return
        }
        if session.welcomesWithRetainedWallets, let restored = pendingRestore {
            Task {
                do {
                    try await session.restoreWallet(restored)
                    pendingRestore = nil
                    session.finishInitialCustomization()
                } catch { OathDiagnostics.record(error, component: "wallet_lifecycle", operation: "restore_after_remote_removal"); retainedCreationFailed = true }
            }
            return
        }
        guard let destination = pendingDestination else { return }
        pendingDestination = nil
        path.append(destination)
    }
}

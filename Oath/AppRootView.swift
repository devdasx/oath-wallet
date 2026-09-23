import Combine
import SwiftUI

#if DEBUG
@MainActor
final class AppResetTestActions {
    var begin: (() -> Void)?
    var complete: (() -> Void)?
}

extension EnvironmentValues {
    @Entry var appResetTestActions: AppResetTestActions? = nil
}
#endif

struct AppRootView: View {
    let database: WalletDatabase
#if DEBUG
    // Lets integration tests observe and invoke the mounted root's real actions.
    var testObserver: ((AppRootView) -> Void)? = nil
#endif

    @Environment(\.scenePhase) var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(WalletSettingsStore.self) var applicationSettings
    @Environment(PushNotificationCoordinator.self)
    var pushNotifications
    @Environment(WalletAppDeepLinkCoordinator.self)
    var deepLinkCoordinator
    @State var confirmedTronChecks: [TronPermissionCheckRecord] = []
    @State var stablecoinFindings: [StablecoinBlacklistRecord] = []
    @State var phase: AppRootPhase = .startup
    @State var walletPresentation = AppRootWalletPresentation.empty()
    @State var walletContextReadinessRequest:
        AppRootWalletContextReadinessRequest?
    @State var walletPortfolioPublicationGeneration: UInt64 = 0
    @State var walletActivityPublicationGeneration: UInt64 = 0
    @State var walletLoadTask: Task<Void, Never>?


    @State var bitcoinFamilyBalanceRefreshTask: Task<Void, Never>?
    @State var bitcoinFamilyBalanceRefreshGeneration: UInt64 = 0
    @State var bitcoinFamilyBalanceMonitorTask: Task<Void, Never>?
    @State var bitcoinFamilyBalanceMonitorRequestID: UUID?
    @State var isSettingsPresented = false
    @State var settingsSheetRootRoute = WalletSettingsSearchRoute.root
    @State var settingsNavigationPath: [WalletSettingsSearchRoute] = []
    @State var settingsSecurityNavigation = SettingsSecurityNavigationState()
    @State var isSettingsSecurityAuthenticationPresented = false
    @State var isSettingsSecurityLoadErrorPresented = false
    @State var deviceMigrationExportNavigation = DeviceMigrationExportNavigationState()
    @State var isDeviceMigrationAuthenticationPresented = false
    @State var isDeviceMigrationAuthorizationErrorPresented = false
    @State var settingsWalletSetupDismissal = SettingsWalletSetupDismissal()
    @State var destructiveFlow = AppRootDestructiveFlowCoordinator()
    @State var isWalletSwitcherPresented = false
    @State var homeWalletAddAction: HomeWalletAddAction?
    @State var walletSwitcherNavigationPath: [WalletSwitcherNavigationRoute] = []
    @State var walletSwitcherRefreshGeneration = UUID()
    @State var walletActionPreparation:
        WalletActionPresentationPreparation?
    @State var walletActionPreparationTask: Task<Void, Never>?
    @State var walletActionPreparationGeneration = UUID()
    @State var walletActionPresentation:
        WalletActionPresentation?
    @State var sendActivities = SendActivityStore()
    @State var pendingActivityReceipt: WalletTransaction?
    @State var postBroadcastChainRefreshTasks:
        [SendPostBroadcastChainRefreshID: SendPostBroadcastRefreshTask] = [:]
    @State var walletHomePasteErrorMessage: String?
    @State var onboardingCompletion = AppRootOnboardingCompletionState()
    @State var isNotificationInboxPresented = false
    @State var notificationToOpenID: String?
    @State var notificationPermissionPrompt = NotificationPermissionPromptState()
    @State private var didRestoreWallet = false
    @State var securitySettings = WalletSecuritySettings.secureDefault
    @State var appLock = WalletAppLockSceneController()
    @State var sensitiveLockPresentation = WalletSensitiveLockPresentationState()
    @State var isPrivacyShieldVisible = false
    @State private var didEnterBackground = false
    @State var walletHomeNavigationResetGeneration: UInt64 = 0
    @State var walletHomeSearchPresentationRequestID: UUID?
    @State private var isWalletRefreshPendingAfterUnlock = false
    @State private var postAuthenticationRefreshHandoff =
        PostAuthenticationWalletRefreshHandoff()
    @State private var isRetryingLaunchSecurity = false
    @State private var isRetryingLaunchRestoration = false
    @State private var appReviewPrompt: AppReviewPromptCoordinator
    init(database: WalletDatabase) {
        self.database = database
        _appReviewPrompt = State(
            initialValue: AppReviewPromptCoordinator(database: database)
        )
    }
    var body: some View {
        ZStack {
            WalletTheme.background
                .ignoresSafeArea()

            switch phase {
            case .startup:
                EmptyView()
            case .onboarding:
                OnboardingView(
                    database: database,
                    onPrepareWalletForOpen: prepareWalletForOpening,
                    onOpenWallet: openWallet
                )
            case let .launchAuthentication(identity, settings):
                LaunchWalletAuthenticationScreen(
                    database: database,
                    settings: settings
                ) {
                    completeLaunchAuthentication(identity)
                }
            case let .launchSecurityUnavailable(identity, issue):
                LaunchSecurityUnavailableScreen(
                    issue: issue,
                    isRetrying: isRetryingLaunchSecurity
                ) { Task { await retryLaunchSecurity(identity) } }
                .appRootDestinationAppearance(
                    reduceMotion: reduceMotion
                )
            case let .launchRestorationUnavailable(failure):
                AppLaunchRestorationFailureScreen(
                    failure: failure,
                    isRetrying: isRetryingLaunchRestoration
                ) {
                    Task {
                        await retryLaunchRestoration()
                    }
                }
                .appRootDestinationAppearance(
                    reduceMotion: reduceMotion
                )
            case .wallet:
                NavigationStack {
                    Group {
                        WalletHomeView(
                            database: database,
                            sendActivities: sendActivities,
                            onPendingTransaction: { pendingActivityReceipt = $0 },
                            walletName: walletName,
                            walletAppearanceColor: walletAppearanceColor,
                            walletAddress: walletAddress,
                            permissionWalletID: walletPresentation.identity?.walletID,
                            capabilities: walletCapabilities,
                            state: walletState,
                            presentationPreparation: currentWalletActionPreparation,
                            homeDisplayPreparation:
                                currentWalletHomeDisplayPreparation,
                            contentRevision:
                                walletPresentation.stateRevision,
                            navigationResetGeneration:
                                walletHomeNavigationResetGeneration,
                            externalSearchPresentationRequestID:
                                walletHomeSearchPresentationRequestID,
                            onFirstRenderedFrame:
                                walletHomeDidRenderFirstFrame,
                            onWalletSwitcher: {
                                presentWalletSwitcher()
                            },
                            onAddWallet: { action in
                                homeWalletAddAction = action
                            },
                            onSettings: {
                                presentSettingsSearchRoute(.root)
                            },
                            onOpenSettingsSearchRoute: { route in
                                presentSettingsSearchRoute(route)
                            },
                            onOpenSettingsQuickAction: { route in
                                presentSettingsQuickAction(route)
                            },
                            onWalletSelectedFromSearch: { wallet in
                                selectWalletFromUniversalSearch(wallet)
                            },
                            onScan: {
                                presentScannerFlow()
                            },
                            onPasteAddress: { payload in
                                presentPastedSendFlow(payload)
                            },
                            onScanAsset: { asset in
                                presentScannerFlow(for: asset)
                            },
                            onPasteAsset: { asset, payload in
                                presentPastedSendFlow(
                                    payload,
                                    for: asset
                                )
                            },
                            onSend: {
                                presentSendFlow()
                            },
                            onSendAsset: { asset in
                                presentSendAsset(asset)
                            },
                            onReceive: {
                                presentReceiveFlow()
                            },
                            onReceiveAsset: { asset in
                                presentReceiveAsset(asset)
                            },
                            onRetry: {
                                reloadWallet(showsLoadingState: true)
                            },
                            onRefresh: {
                                refreshWallet()
                            },
                            isAppSwitcherPrivacyActive:
                                isAppSwitcherPrivacyActive
                        )
                        .sheet(
                            isPresented: $isWalletSwitcherPresented,
                            onDismiss: walletSwitcherDidDismiss
                        ) {
                            WalletSwitcherSheet(
                                database: database,
                                isAppSwitcherPrivacyActive:
                                    isAppSwitcherPrivacyActive,
                                refreshGeneration:
                                    walletSwitcherRefreshGeneration,
                                path: $walletSwitcherNavigationPath,
                                onWalletSelected: { wallet, address in
                                    let requestID = loadWalletAddress(
                                        address,
                                        suggestedName: wallet.name,
                                        suggestedAppearanceColor: wallet.appearanceColor
                                    )
                                    return await awaitWalletContextReadiness(
                                        requestID: requestID
                                    )
                                },
                                onWalletAdded: completeHomeWalletAdd,
                                onDismissRequested: {
                                    isWalletSwitcherPresented = false
                                }
                            ) { walletID in
                                walletSwitcherSettingsDestination(walletID: walletID)
                            }
                            .walletSheetPresentation(nativeGlass: false)
                            .walletCoveringModal(
                                .homeWalletSwitcher,
                                callbacks: coveringModalCallbacks
                            )
                            .walletAppLockOverlay(
                                isPresented: shouldShowWalletLock(
                                    in: .homeWalletSwitcher
                                ),
                                database: database,
                                settings: securitySettings,
                                onAuthenticated: unlockWallet
                            )
                            .presentationDetents(
                                WalletSwitcherSheetDetentPolicy.allowedDetents
                            )
                            .presentationDragIndicator(.visible)
                        }
                        .sheet(
                            item: $homeWalletAddAction,
                            onDismiss: homeWalletAddDidDismiss
                        ) { action in
                            HomeWalletAddSheet(
                                database: database,
                                action: action,
                                onWalletAdded: completeHomeWalletAdd
                            )
                            .walletSheetPresentation(nativeGlass: action.sheetDetent == .medium)
                            .walletCoveringModal(
                                .homeWalletAdd,
                                callbacks: coveringModalCallbacks
                            )
                            .walletAppLockOverlay(
                                isPresented: shouldShowWalletLock(
                                    in: .homeWalletAdd
                                ),
                                database: database,
                                settings: securitySettings,
                                onAuthenticated: unlockWallet
                            )
                            .presentationDetents([
                                action.sheetDetent.presentationDetent
                            ])
                            .presentationDragIndicator(.visible)
                        }
                        .sheet(
                            isPresented: $isSettingsPresented,
                            onDismiss: settingsDidDismiss
                        ) {
                            settingsSheetContent
                        }
                        .sheet(
                            isPresented: $isNotificationInboxPresented,
                            onDismiss: notificationInboxDidDismiss
                        ) {
                            NavigationStack {
                                Group {
                                    PushNotificationInboxScreen(
                                        database: database, initialNotificationID: notificationToOpenID
                                    )
                                }

                            }
                            .walletSheetPresentation(nativeGlass: false)
                            .walletCoveringModal(.notificationInbox, callbacks: coveringModalCallbacks)
                            .walletAppLockOverlay(
                                isPresented: shouldShowWalletLock(
                                    in: .notificationInbox
                                ),
                                database: database,
                                settings: securitySettings,
                                onAuthenticated: unlockWallet
                            )
                            .presentationDetents([.large])
                            .presentationDragIndicator(.visible)
                        }
                    }

                }
            }
        }
        .environment(
            \.walletTransactionRepeatAction,
            WalletTransactionRepeatAction { transaction in
                await presentRepeatedTransaction(transaction)
            }
        )
        .sheet(
            item: $walletActionPresentation,
            onDismiss: walletActionSheetDidDismiss
        ) { presentation in
            WalletActionPresentationSheet(
                presentation: presentation,
                currentPreparation: $walletActionPreparation,
                currentBalanceSource: Binding(
                    get: { currentWalletActionBalanceSource },
                    set: { _ in }
                ),
                database: database,
                onAssetSelected: enableAssetVisibility,
                resolveScannedRoute:
                    resolveScannedWalletActionRoute,
                onPresentationAppeared:
                    walletActionPresentationDidAppear,
                onTransactionBroadcast: { request in
                    schedulePostBroadcastChainRefresh(
                        request: request,
                        context: presentation.context
                    )
                },
                onModalDismissed:
                    coveringModalDidDismiss
            )
            .id(presentation.id)
            .walletAppLockOverlay(
                isPresented:
                    isWalletLocked
                    && sensitiveLockPresentation.hasPresentedModal,
                database: database,
                settings: securitySettings,
                onAuthenticated: unlockWallet
            )
        }
        .alert(
            WalletLocalization.string(
                "wallet.home.paste.error.title"
            ),
            isPresented: walletHomePasteErrorIsPresented
        ) {
            Button("common.ok", role: .cancel, action: UniHaptic.action {
                walletHomePasteErrorMessage = nil
            })
        } message: {
            Text(verbatim: walletHomePasteErrorMessage ?? "")
        }
        .modifier(sendActivityPresentation)
        .modifier(pendingActivityReceiptPresentation)
        .environment(sendActivities)
        .environment(\.walletMultisigRestricted, isWalletMultisigRestricted)
        .task { await observeConfirmedTronChecks() }
        .task(id: walletValuationRefreshID) { await refreshVisibleWalletPrices() }
        .environment(\.stablecoinBlacklistFindings, stablecoinFindings)
        .task { await observeStablecoinFindings() }
        .postCreationWalletBackupSheet(
            presentation: $onboardingCompletion.backupPresentation,
            database: database,
            securitySettings: securitySettings,
            showsWalletLock: shouldShowWalletLock(
                in: .postCreationWalletBackup
            ),
            callbacks: coveringModalCallbacks,
            onAuthenticated: unlockWallet,
            onBackupCompleted: postCreationWalletBackupDidComplete,
            onDismiss: postCreationWalletBackupDidDismiss
        )
        .modifier(settingsSecurityPresentation(for: .home))
        .fullScreenCover(
            item: $destructiveFlow.presentation,
            onDismiss: destructiveFlowDidDismiss
        ) { presentation in
            destructiveFlowDestination(presentation)
        }
        .appReviewPromptPresentation(
            coordinator: appReviewPrompt,
            database: database,
            securitySettings: securitySettings,
            showsWalletLock: shouldShowWalletLock(
                in: .appReviewPrompt
            ),
            callbacks: coveringModalCallbacks,
            onAuthenticated: unlockWallet
        )
        .task(id: appReviewLifecycleContext) {
            let context = appReviewLifecycleContext
            appReviewPrompt.start(
                isUsageActive: context.isUsageActive,
                canPresentSheet: context.canPresentSheet
            )
        }
        .task {
            let catalogWarmup = Task {
                await WalletActionCatalogPrewarmer.shared.prepare()
            }
            await restoreSelectedWalletIfNeeded()
            await catalogWarmup.value
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .walletAssetCatalogDidChange
            )
        ) { _ in
            assetCatalogDidChange()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .walletSecuritySettingsDidChange
            )
        ) { _ in
            Task {
                await refreshSecuritySettings()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhase(newPhase)
        }
        .onChange(of: pushNotifications.pendingRoute) {
            _, route in
            guard route != nil else { return }
            presentPendingNotificationIfPossible()
        }
        .onChange(of: canRequestNotificationPermission, initial: true) {
            _, canRequest in
            if canRequest { requestNotificationPermissionIfNeeded() }
        }
        .onChange(
            of: applicationSettings.assetVisibilityPreferencesJSON
        ) { _, _ in
            scheduleWalletActionPreparation()
        }
        .walletEntropyEventDeepLink(database: database) { address in
            handleEntropyEventWalletCreated(address, coordinator: deepLinkCoordinator)
        }
        .task(id: agentDeepLinkPresentationContext) {
            await Task.yield()
            presentPendingAgentDeepLinkIfPossible()
        }
        .onChange(of: phase) { _, _ in
            openDeferredEntropyEventWalletIfPossible(coordinator: deepLinkCoordinator)
        }
#if DEBUG
        .onChange(of: phase, initial: true) { _, _ in testObserver?(self) }
        .onChange(of: destructiveFlow) { _, _ in testObserver?(self) }
#endif
        .walletCallSafetyBanner()
        .walletSensitiveContentMask(
            isProtected: scenePhase != .active
        )
        .environment(
            \.walletPrivacyShieldEnabled,
            securitySettings.privacyShieldEnabled
        )
        .environment(\.walletAppLockIsPresented, isWalletLocked)
        .background {
            WalletAppLockSceneBridge(
                controller: appLock,
                database: database,
                settings: securitySettings,
                enabled: phase == .wallet,
                onAuthenticated: unlockWallet
            )
            .frame(width: 0, height: 0)
        }
    }

    @MainActor
    func openWallet(address: String) {
        if let prepared = walletPresentation.resolvedContext,
           AppRootWalletAddressMatcher.matches(
               prepared.identity.address,
               address
           ) {
            activateWalletHome()
            return
        }
        let requestID = loadWalletAddress(address)
        Task { @MainActor in
            guard await awaitWalletContextReadiness(
                requestID: requestID
            ) else {
                return
            }
            await refreshSecuritySettings()
            activateWalletHome()
        }
    }

    @MainActor
    private func prepareWalletForOpening(address: String) async -> Bool {
        let requestID = loadWalletAddress(address)
        guard await awaitWalletContextReadiness(requestID: requestID) else {
            return false
        }
        await refreshSecuritySettings()
        return true
    }

    @MainActor
    private func restoreSelectedWalletIfNeeded() async {
        guard !didRestoreWallet else { return }
        didRestoreWallet = true
        await restoreWalletForLaunch(
            source: "fresh_launch"
        )
    }

    @MainActor
    private func retryLaunchRestoration() async {
        guard !isRetryingLaunchRestoration else { return }
        isRetryingLaunchRestoration = true
        defer { isRetryingLaunchRestoration = false }
        await restoreWalletForLaunch(
            source: "manual_retry"
        )
    }

    @MainActor
    private func restoreWalletForLaunch(
        source: String
    ) async {
        let result = await AppLaunchWalletRestorationService(
            database: database
        ).restore()

        switch result {
        case .noWallets:
            phase = .onboarding
        case let .failed(failure):
            phase = .launchRestorationUnavailable(failure)
        case let .wallet(payload):
            let accountAddresses: WalletAccountAddressIndex
            do {
                accountAddresses = try await database.accountAddressIndex(
                    walletID: payload.identity.walletID
                )
                guard accountAddresses.accountCount > 0 else {
                    throw WalletDataStoreError.invalidState
                }
            } catch {
                phase = .launchRestorationUnavailable(
                    AppLaunchWalletRestorationFailure(
                        error: error,
                        stage: .accountAddresses
                    )
                )
                return
            }
            let context = AppRootResolvedWalletContext(
                requestID: UUID(),
                identity: payload.identity,
                name: payload.walletName,
                capabilities: payload.capabilities,
                appearanceColor: payload.walletAppearanceColor,
                accountAddresses: accountAddresses
            )
            isWalletRefreshPendingAfterUnlock = true
            walletPresentation = .resolved(
                context: context,
                state: payload.cachedSnapshot.map {
                    .content(
                        payload.capabilities.scopedSnapshot($0)
                    )
                } ?? .loading
            )
            scheduleWalletActionPreparation()
            await resolveLaunchAuthentication(
                payload.identity,
                source: source
            )
        }
    }

    @MainActor
    private func resolveLaunchAuthentication(
        _ identity: PersistedWalletIdentity,
        source: String
    ) async {
        do {
            securitySettings = try await database.walletSecuritySettings()
            let credentialReadiness:
            WalletPasscodeCredentialReadiness
            if securitySettings.requiresAuthentication {
                let resolver = WalletLaunchPasscodeCredentialResolver(
                    database: database
                )
                credentialReadiness = try await resolver.resolve()
            } else {
                credentialReadiness = .protectionDisabled
            }

            guard walletPresentation.identity == identity else {
                return
            }
            let requestID = walletPresentation.requestID
            guard await awaitWalletActionReadiness(
                requestID: requestID,
                requirement: .currentSnapshot
            ) else {
                return
            }

            switch AppLaunchSecurityRoutingPolicy.route(
                settings: securitySettings,
                credentialReadiness: credentialReadiness
            ) {
            case .authentication:
                phase = .launchAuthentication(
                    identity,
                    securitySettings
                )
            case .wallet:
                completeLaunchAuthentication(identity)
            case let .unavailable(issue):
                phase = .launchSecurityUnavailable(identity, issue)
            }
        } catch {
            phase = .launchSecurityUnavailable(
                identity,
                .databaseUnavailable
            )
        }
    }

    @MainActor
    private func retryLaunchSecurity(_ identity: PersistedWalletIdentity) async {
        guard !isRetryingLaunchSecurity else { return }
        isRetryingLaunchSecurity = true
        defer { isRetryingLaunchSecurity = false }
        await resolveLaunchAuthentication(
            identity, source: "security_retry"
        )
    }

    @MainActor
    private func completeLaunchAuthentication(
        _ identity: PersistedWalletIdentity
    ) {
        let refreshAfterActivation: Bool
        let requestID: UUID
        if walletPresentation.resolvedContext?.identity == identity {
            requestID = walletPresentation.requestID
            refreshAfterActivation = true
            if currentWalletActionPreparation == nil,
               currentWalletStableActionPreparation == nil {
                scheduleWalletActionPreparation()
            }
        } else {
            requestID = loadWalletAddress(identity.address)
            refreshAfterActivation = false
        }

        Task { @MainActor in
            let isReady = await awaitWalletActionReadiness(
                requestID: requestID,
                requirement: .currentSnapshot
            )
            guard isReady else { return }
            if refreshAfterActivation {
                postAuthenticationRefreshHandoff.stage(
                    requestID: requestID,
                    identity: identity
                )
            }
            activateWalletHome()
        }
    }

    @MainActor
    private func walletHomeDidRenderFirstFrame() {
        UniHaptic.prepareWalletActionControls()
        presentOnboardingCompletionActionIfNeeded()
        let consumesRefresh = phase == .wallet
            && postAuthenticationRefreshHandoff
                .consumeAfterFirstRenderedFrame(
                    requestID: walletPresentation.requestID,
                    identity: walletPresentation.identity
                )
        guard consumesRefresh else { return }
        reloadWallet(showsLoadingState: false)
    }

    @MainActor
    private func activateWalletHome() {
        isWalletLocked = false
        sensitiveLockPresentation.reset()
        isPrivacyShieldVisible = false
        phase = .wallet
        isWalletRefreshPendingAfterUnlock = false
        presentPendingNotificationIfPossible()
    }

    @MainActor
    func completeAppReset() {
        destructiveFlow.dismissAfterCompletion(.appReset)
    }

    @MainActor
    func finishAppResetAfterDismissal() {
        sendActivities.clear()
        destructiveFlow.cancel()
        walletContextReadinessRequest?.gate.resolve(false)
        walletContextReadinessRequest = nil
        walletLoadTask?.cancel()
        walletLoadTask = nil
        cancelBitcoinFamilyBalanceRefresh()
        cancelBitcoinFamilyBalanceMonitor()
        cancelPostBroadcastChainRefreshes()
        invalidateWalletActionPreparation()
        walletPresentation = .empty()
        onboardingCompletion.cancel()
        isSettingsPresented = false
        walletSwitcherNavigationPath.removeAll(keepingCapacity: false)
        isWalletSwitcherPresented = false
        homeWalletAddAction = nil
        walletActionPresentation = nil
        isNotificationInboxPresented = false
        isWalletLocked = false
        sensitiveLockPresentation.reset()
        isPrivacyShieldVisible = false
        didEnterBackground = false
        walletHomeNavigationResetGeneration &+= 1
        isWalletRefreshPendingAfterUnlock = false
        postAuthenticationRefreshHandoff.reset()
        securitySettings = .secureDefault
        // Reset already committed and verified the empty database. Re-running
        // launch restoration here can leave an empty root under a dismissing cover.
        didRestoreWallet = true
        phase = .onboarding
    }

    @MainActor
    func returnToOnboarding() {
        sendActivities.clear()
        PushNotificationCoordinator.shared.walletDataDidChange()
        walletContextReadinessRequest?.gate.resolve(false)
        walletContextReadinessRequest = nil
        walletLoadTask?.cancel()
        walletLoadTask = nil
        cancelBitcoinFamilyBalanceRefresh()
        cancelBitcoinFamilyBalanceMonitor()
        invalidateWalletActionPreparation()
        walletPresentation = .empty()
        onboardingCompletion.cancel()
        isSettingsPresented = false
        walletSwitcherNavigationPath.removeAll(keepingCapacity: false)
        isWalletSwitcherPresented = false
        homeWalletAddAction = nil
        walletActionPresentation = nil
        isNotificationInboxPresented = false
        isWalletLocked = false
        sensitiveLockPresentation.reset()
        isPrivacyShieldVisible = false
        didEnterBackground = false
        walletHomeNavigationResetGeneration &+= 1
        isWalletRefreshPendingAfterUnlock = false
        postAuthenticationRefreshHandoff.reset()
        phase = .onboarding
    }

    @MainActor
    private func refreshSecuritySettings() async {
        guard let updated = try? await database.walletSecuritySettings() else {
            return
        }
        securitySettings = updated
        if !updated.requiresAuthentication {
            isWalletLocked = false
            sensitiveLockPresentation.didUnlock()
        }
        if !updated.privacyShieldEnabled {
            isPrivacyShieldVisible = false
        }
    }

    @MainActor
    func unlockWallet() {
        isWalletLocked = false
        sensitiveLockPresentation.didUnlock()
        let shouldRefresh = isWalletRefreshPendingAfterUnlock
        isWalletRefreshPendingAfterUnlock = false

        if shouldRefresh {
            reloadWallet(showsLoadingState: false)
        }
        presentPendingNotificationIfPossible()
    }

    @MainActor
    private func handleScenePhase(_ newPhase: ScenePhase) {
        switch newPhase {
        case .active:
            resumeSettingsSecurityNavigationAfterInactive()
            resumeDeviceMigrationExportNavigationAfterInactive()
        case .background:
            invalidateSettingsSecurityNavigationForBackground()
            invalidateDeviceMigrationExportNavigationForBackground()
        case .inactive:
            break
        @unknown default:
            invalidateSettingsSecurityNavigationForBackground()
            invalidateDeviceMigrationExportNavigationForBackground()
        }

        guard phase == .wallet else {
            isPrivacyShieldVisible = false
            return
        }

        switch newPhase {
        case .active:
            // UIKit has already covered the scene before this SwiftUI update.
            // Recheck elapsed continuous time without changing any routes.
            appLock.requireLockIfExpired()
            isPrivacyShieldVisible = false
            guard didEnterBackground else { return }
            didEnterBackground = false
            if isWalletAccessRestricted {
                isWalletRefreshPendingAfterUnlock = true
            } else {
                isWalletRefreshPendingAfterUnlock = false
                reloadWallet(showsLoadingState: false)
            }
            presentPendingNotificationIfPossible()
        case .inactive:
            applySceneSecurityTransition(event: .inactive)
        case .background:
            didEnterBackground = true
            isWalletRefreshPendingAfterUnlock = true
            cancelBitcoinFamilyBalanceMonitor()
            applySceneSecurityTransition(event: .background)
        @unknown default:
            isPrivacyShieldVisible =
                securitySettings.privacyShieldEnabled
        }
    }

    @MainActor
    private func applySceneSecurityTransition(
        event: WalletSceneSecurityEvent
    ) {
        let plan = WalletSceneSecurityTransitionPlan.make(
            event: event,
            locksImmediately:
                securitySettings.requiresAuthentication
                    && securitySettings.autoLockDuration == .immediately
        )
        for action in plan.actions {
            switch action {
            case .applyConfiguredPrivacyShield:
                isPrivacyShieldVisible =
                    securitySettings.privacyShieldEnabled
            case .lockWallet:
                requestWalletLock()
            }
        }
    }

    @MainActor
    func presentPendingNotificationIfPossible() {
        guard phase == .wallet, !isWalletAccessRestricted,
              !onboardingCompletion.isBlockingHomePresentation,
              pushNotifications.pendingRoute != nil else {
            return
        }
        dismissPresentedWalletSheets()
        notificationToOpenID = pushNotifications.consumePendingRoute()?.notificationID
        isNotificationInboxPresented = true
    }

    private func dismissPresentedWalletSheets() {
        pendingActivityReceipt = nil
        sendActivities.isActivityListPresented = false
        sendActivities.presentedOperation = nil
        sendActivities.pendingRetry = nil
        walletSwitcherNavigationPath.removeAll(keepingCapacity: false)
        isWalletSwitcherPresented = false
        homeWalletAddAction = nil
        settingsSecurityNavigation.clear()
        isSettingsSecurityAuthenticationPresented = false
        isSettingsSecurityLoadErrorPresented = false
        isSettingsPresented = false
        walletActionPresentation = nil
        isNotificationInboxPresented = false
        notificationToOpenID = nil
        onboardingCompletion.cancel()
    }

    private var appReviewLifecycleContext:
        AppReviewLifecycleContext {
        let isUsageActive = phase == .wallet
            && scenePhase == .active
            && !isWalletLocked
        let hasCompetingPresentation =
            sensitiveLockPresentation.hasPresentedModal
            || isSettingsPresented
            || settingsSecurityNavigation.isAwaitingAuthorization
            || isSettingsSecurityAuthenticationPresented
            || settingsSecurityNavigation.isPasscodePresentationActive
            || isWalletSwitcherPresented
            || homeWalletAddAction != nil
            || walletActionPresentation != nil
            || destructiveFlow.presentation != nil
            || onboardingCompletion.isBlockingHomePresentation
            || isNotificationInboxPresented
        return AppReviewLifecycleContext(
            isUsageActive: isUsageActive,
            canPresentSheet:
                isUsageActive && !hasCompetingPresentation
        )
    }

    @MainActor
    private func requestWalletLock() {
        _ = sensitiveLockPresentation.requestLock()
        isWalletLocked = true
    }

}

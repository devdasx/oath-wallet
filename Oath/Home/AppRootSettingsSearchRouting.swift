import SwiftUI

extension AppRootView {
    func settingsSecurityPresentation(
        for host: SettingsSecurityPresentationHost
    ) -> some ViewModifier {
        SettingsSecurityPresentationModifier(
            isAuthenticationPresented: Binding(
                get: {
                    settingsSecurityNavigation.presentationHost == host
                        && isSettingsSecurityAuthenticationPresented
                },
                set: { isSettingsSecurityAuthenticationPresented = $0 }
            ),
            isLoadErrorPresented: Binding(
                get: {
                    settingsSecurityNavigation.presentationHost == host
                        && isSettingsSecurityLoadErrorPresented
                },
                set: { isSettingsSecurityLoadErrorPresented = $0 }
            ),
            context: settingsSecurityNavigation.passcodeContext,
            database: database,
            onAuthenticated: completeSettingsSecurityPasscodeAuthentication,
            onDismiss: settingsSecurityAuthenticationDidDismiss,
            onRetry: requestSettingsSecurityAccess
        )
    }

    var settingsSheetContent: some View {
        SettingsSheetNavigationContainer(
            path: $settingsNavigationPath,
            securityDidExit: settingsSecurityNavigationDidExit,
            onClose: closeSettingsSheet
        ) {
            if settingsSheetRootRoute == .root {
                WalletSettingsView(
                    isSecurityAuthorizationInProgress:
                        settingsSecurityNavigation.isAwaitingAuthorization,
                    onSecurityRequested: requestSettingsSecurityAccess,
                    onResetRequested: requestResetAppDataFlow
                )
            } else {
                settingsSearchDestination(for: settingsSheetRootRoute)
            }
        } destination: { route in
            settingsSearchDestination(for: route)
        }
        .walletSheetPresentation(nativeGlass: false)
        .walletCoveringModal(
            .settings,
            callbacks: coveringModalCallbacks
        )
        .walletAppLockOverlay(
            isPresented: shouldShowWalletLock(in: .settings),
            database: database,
            settings: securitySettings,
            onAuthenticated: unlockWallet
        )
        .modifier(settingsSecurityPresentation(for: .settings))
        .fullScreenCover(
            isPresented: $isDeviceMigrationAuthenticationPresented,
            onDismiss: deviceMigrationAuthenticationDidDismiss
        ) {
            if let context =
                deviceMigrationExportNavigation.passcodeContext {
                WalletAuthenticationFullScreenContainer(
                    title: "security.authentication.navigation_title"
                ) {
                    DeviceMigrationExportAuthenticationScreen(
                        database: database,
                        settings: context.settings,
                        beginsWithPasscode: true,
                        initialErrorKey: context.initialErrorKey
                    ) { authorization in
                        completeDeviceMigrationExportPasscodeAuthentication(
                            authorization
                        )
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .alert(
            "device_migration.export.title",
            isPresented: $isDeviceMigrationAuthorizationErrorPresented
        ) {
            Button("common.retry", action: UniHaptic.action {
                requestDeviceMigrationExportAccess()
            })
            Button("common.cancel", role: .cancel, action: UniHaptic.action {})
        } message: {
            Text("device_migration.authentication.unavailable")
        }
    }

    @MainActor
    func presentSettingsSearchRoute(
        _ route: WalletSettingsSearchRoute
    ) {
        settingsSheetRootRoute = .root
        if route == .reset {
            requestResetAppDataFlow()
            return
        }

        if route == .security {
            requestSettingsSecurityAccess()
            return
        }

        settingsWalletSetupDismissal.cancel()
        settingsNavigationPath = route == .root ? [] : [route]
        isSettingsPresented = true
    }

    @MainActor
    func presentSettingsQuickAction(_ route: WalletSettingsSearchRoute) {
        settingsWalletSetupDismissal.cancel()
        settingsSheetRootRoute = route
        settingsNavigationPath.removeAll()
        if route == .security {
            requestSettingsSecurityAccess()
        } else {
            isSettingsPresented = true
        }
    }

    @MainActor
    func closeSettingsSheet() {
        // Invalidate pending authorization before dismissal so its completion
        // cannot present the sheet again after Close.
        settingsSecurityNavigation.clear()
        deviceMigrationExportNavigation.clear()
        isSettingsPresented = false
    }

    @MainActor
    func requestSettingsSecurityAccess() {
        guard let requestID =
            settingsSecurityNavigation.beginAuthorization(
                from: isSettingsPresented ? .settings : .home
            ) else {
            return
        }

        if !isSettingsPresented {
            settingsWalletSetupDismissal.cancel()
            settingsNavigationPath.removeAll()
        }

        Task { @MainActor in
            do {
                let settings = try await database.walletSecuritySettings()
                guard settingsSecurityNavigation.activeRequestID == requestID else {
                    return
                }
                let preparation = await SettingsSecurityAccessAuthorizer.prepare(
                    settings: settings
                )
                guard settingsSecurityNavigation.activeRequestID == requestID else {
                    return
                }
                settingsSecurityNavigation.receive(
                    preparation,
                    requestID: requestID,
                    sceneIsActive: scenePhase == .active,
                    sceneIsBackground: scenePhase == .background
                )
                presentPendingSettingsSecurityNavigation()
            } catch {
                guard settingsSecurityNavigation.activeRequestID == requestID else {
                    return
                }
                settingsSecurityNavigation.fail(requestID: requestID)
                isSettingsSecurityLoadErrorPresented = true
            }
        }
    }

    @MainActor
    func settingsSecurityNavigationDidExit() {
        settingsSecurityNavigation.clear()
        isSettingsSecurityAuthenticationPresented = false
        isSettingsSecurityLoadErrorPresented = false
    }

    @MainActor
    func resumeSettingsSecurityNavigationAfterInactive() {
        settingsSecurityNavigation.resumeAfterInactive()
        presentPendingSettingsSecurityNavigation()
    }

    @MainActor
    func invalidateSettingsSecurityNavigationForBackground() {
        settingsSecurityNavigation.invalidateForBackground()
    }

    @MainActor
    func completeSettingsSecurityPasscodeAuthentication() {
        settingsSecurityNavigation.acceptAfterPasscode(
            sceneIsBackground: scenePhase == .background
        )
        isSettingsSecurityAuthenticationPresented = false
    }

    @MainActor
    func settingsSecurityAuthenticationDidDismiss() {
        settingsSecurityNavigation.passcodeAuthenticationDidDismiss()
        presentPendingSettingsSecurityNavigation()
    }

    @MainActor
    func presentPendingSettingsSecurityNavigation() {
        guard scenePhase != .background,
              let presentation = settingsSecurityNavigation
                .takePendingPresentation(sceneIsActive: scenePhase == .active) else {
            return
        }

        settingsWalletSetupDismissal.cancel()
        switch presentation {
        case .settings:
            // Cancellation stays at the entry point: Home or existing Settings.
            isSettingsSecurityAuthenticationPresented = false
            settingsSecurityNavigation.clear()
        case .security:
            isSettingsSecurityAuthenticationPresented = false
            settingsNavigationPath = SettingsSheetNavigationPath.relative(
                [.security], to: settingsSheetRootRoute
            )
            isSettingsPresented = true
        case .passcode:
            isSettingsSecurityAuthenticationPresented = true
        }
    }

    @MainActor
    func requestDeviceMigrationExportAccess() {
        guard let requestID =
            deviceMigrationExportNavigation.beginAuthorization() else {
            return
        }

        Task { @MainActor in
            do {
                let preparation =
                    try await DeviceMigrationExportDestinationAuthorizer
                        .prepare(database: database)
                deviceMigrationExportNavigation.receive(
                    preparation,
                    requestID: requestID,
                    sceneIsActive: scenePhase == .active,
                    sceneIsBackground: scenePhase == .background
                )
                presentPendingDeviceMigrationExportNavigation()
            } catch {
                deviceMigrationExportNavigation.fail(
                    requestID: requestID
                )
                isDeviceMigrationAuthorizationErrorPresented = true
            }
        }
    }

    @MainActor
    func resumeDeviceMigrationExportNavigationAfterInactive() {
        deviceMigrationExportNavigation.resumeAfterInactive()
        presentPendingDeviceMigrationExportNavigation()
    }

    @MainActor
    func invalidateDeviceMigrationExportNavigationForBackground() {
        deviceMigrationExportNavigation.invalidateForBackground()
    }

    @MainActor
    func completeDeviceMigrationExportPasscodeAuthentication(
        _ authorization: WalletDeviceMigrationAuthorization
    ) {
        deviceMigrationExportNavigation.acceptAfterPasscode(
            authorization,
            sceneIsBackground: scenePhase == .background
        )
        isDeviceMigrationAuthenticationPresented = false
    }

    @MainActor
    func deviceMigrationAuthenticationDidDismiss() {
        deviceMigrationExportNavigation.passcodeAuthenticationDidDismiss()
        presentPendingDeviceMigrationExportNavigation()
    }

    @MainActor
    func presentPendingDeviceMigrationExportNavigation() {
        guard scenePhase != .background,
              let presentation = deviceMigrationExportNavigation
                .takePendingPresentation(sceneIsActive: scenePhase == .active) else {
            return
        }

        isSettingsPresented = true
        switch presentation {
        case .export:
            isDeviceMigrationAuthenticationPresented = false
            settingsNavigationPath = SettingsSheetNavigationPath.relative(
                [.security, .deviceMigrationExport], to: settingsSheetRootRoute
            )
        case .passcode:
            settingsNavigationPath = SettingsSheetNavigationPath.relative(
                [.security], to: settingsSheetRootRoute
            )
            isDeviceMigrationAuthenticationPresented = true
        }
    }

    @MainActor
    func selectWalletFromUniversalSearch(
        _ wallet: ManagedWallet
    ) {
        Task { @MainActor in
            guard
                let identity = try? await database.selectWallet(
                    walletID: wallet.id
                )
            else {
                return
            }
            PushNotificationCoordinator.shared.walletDataDidChange()
            loadWalletAddress(
                identity.address,
                suggestedName: wallet.name,
                suggestedAppearanceColor: wallet.appearanceColor
            )
        }
    }

    @ViewBuilder
    func settingsSearchDestination(
        for route: WalletSettingsSearchRoute
    ) -> some View {
        switch route {
        case .root:
            EmptyView()
        case .wallets:
            WalletManagementSettingsView(
                database: database,
                initialWalletSettingsID:
                    settingsWalletIDRestoredAfterDestructiveFlow,
                onWalletSelected: { address in
                    loadWalletAddress(address)
                },
                onWalletRenamed: { address, name in
                    PushNotificationCoordinator.shared
                        .walletDataDidChange()
                    updateCurrentWalletName(
                        address: address,
                        name: name
                    )
                },
                onWalletAppearanceChanged: { walletID, color in
                    updateCurrentWalletAppearanceColor(
                        walletID: walletID,
                        color: color
                    )
                },
                onWalletSetupCompleted: { address in
                    completeSettingsWalletSetup(address: address)
                },
                onRemoveWalletRequested:
                    requestSettingsWalletRemoval
            )
        case .security:
            if let settings =
                settingsSecurityNavigation.authorizedSettings {
                SecuritySettingsView(
                    database: database,
                    initialSettings: settings,
                    isDeviceMigrationAuthorizationInProgress:
                        deviceMigrationExportNavigation.isAuthorizing,
                    onDeviceMigrationRequested:
                        requestDeviceMigrationExportAccess
                )
            } else {
                SettingsSecurityAccessUnavailableView(
                    isAwaitingAuthorization:
                        settingsSecurityNavigation.isAwaitingAuthorization,
                    retry: requestSettingsSecurityAccess
                )
            }
        case .deviceMigrationExport:
            if let authorization =
                deviceMigrationExportNavigation.authorization {
                DeviceMigrationExportFlow(
                    database: database,
                    authorization: authorization
                )
            } else {
                DeviceMigrationExportAccessUnavailableView {
                    settingsNavigationPath = SettingsSheetNavigationPath.relative(
                        [.security], to: settingsSheetRootRoute
                    )
                    requestDeviceMigrationExportAccess()
                }
            }
        case .appearance:
            AppearanceSettingsView()
        case .language:
            AppLanguageSettingsView()
        case .currency:
            CurrencySettingsView()
        case .backupAndKeys:
            SettingsBackupWalletSelectionScreen(
                database: database,
                onWalletSelected: { wallet in
                    settingsNavigationPath.append(
                        .backupMaterial(wallet: wallet)
                    )
                },
                onOnlyWalletSelected: { wallet in
                    let route = WalletSettingsSearchRoute.backupMaterial(wallet: wallet)
                    if settingsSheetRootRoute == .backupAndKeys {
                        settingsSheetRootRoute = route
                    } else {
                        settingsNavigationPath.append(route)
                    }
                }
            )
        case let .backupMaterial(wallet):
            SettingsBackupMaterialSelectionScreen(
                database: database,
                wallet: wallet,
                onRecoveryPhraseSelected: {
                    settingsNavigationPath.append(
                        .backupMethod(
                            walletID: wallet.id,
                            material: .recoveryPhrase
                        )
                    )
                }
            )
        case let .backupMethod(walletID, material):
            SettingsBackupMethodSelectionScreen(
                database: database,
                walletID: walletID,
                material: material
            )
        case .tools:
            ToolsSettingsView(database: database)
        case .currencyConverter:
            CurrencyConverterView(database: database)
        case .networkFeeDashboard:
            NetworkFeeDashboardView(database: database)
        case .transactionExport:
            TransactionExportView(database: database)
        case let .networkFeeDetails(networkID):
            NetworkFeeDetailsView(database: database, networkID: networkID)
        case .bitcoinTransactionBroadcaster:
            BitcoinTransactionBroadcastView()
        case .mnemonicLastWordFinder:
            MnemonicLastWordFinderView()
        case .evmAccessManager:
            EVMAccessManagerView(database: database)
        case let .evmApprovalReview(approval):
            EVMApprovalReviewScreen(
                database: database,
                approval: approval
            )
        case .notifications:
            NotificationSettingsView()
        case .about:
            AboutSettingsView()
        case .reset:
            EmptyView()
        }
    }

    @MainActor
    func completeSettingsWalletSetup(address: String) {
        guard settingsWalletSetupDismissal.request(
            walletAddress: address
        ) else {
            return
        }
        isSettingsPresented = false
    }

    @MainActor
    func settingsDidDismiss() {
        let startsDestructiveFlow =
            destructiveFlow.sourceDidDismiss(.settings)
        settingsNavigationPath.removeAll()
        settingsSheetRootRoute = .root
        isSettingsSecurityAuthenticationPresented = false
        settingsSecurityNavigation.clear()
        isSettingsSecurityLoadErrorPresented = false
        deviceMigrationExportNavigation.clear()
        isDeviceMigrationAuthenticationPresented = false
        isDeviceMigrationAuthorizationErrorPresented = false
        coveringModalDidDismiss(.settings)

        if startsDestructiveFlow {
            return
        }
        destructiveFlow.sourceRestorationDidEnd(.settings)

        guard
            let address =
                settingsWalletSetupDismissal
                .consumeAfterSettingsDismissal()
        else {
            return
        }

        PushNotificationCoordinator.shared.walletDataDidChange()
        if let context = walletPresentation.resolvedContext,
           AppRootWalletAddressMatcher.matches(context.identity.address, address) {
            return
        }
        loadWalletAddress(address)
    }
}

/// Hosts the Security flow's existing passcode screen at its entry point.
private struct SettingsSecurityPresentationModifier: ViewModifier {
    @Binding var isAuthenticationPresented: Bool
    @Binding var isLoadErrorPresented: Bool
    let context: SettingsSecurityPasscodeContext?
    let database: WalletDatabase
    let onAuthenticated: () -> Void
    let onDismiss: () -> Void
    let onRetry: () -> Void

    func body(content: Content) -> some View {
        content
            .fullScreenCover(
                isPresented: $isAuthenticationPresented,
                onDismiss: onDismiss
            ) {
                if let context {
                    WalletAuthenticationFullScreenContainer(
                        title: "security.authentication.navigation_title"
                    ) {
                        WalletSecurityAuthenticationView(
                            database: database,
                            settings: context.settings,
                            purpose: .settings,
                            beginsWithPasscode: true,
                            initialErrorKey: context.initialErrorKey,
                            onAuthenticated: onAuthenticated
                        )
                    }
                }
            }
            .alert(
                "settings.security.load.error.title",
                isPresented: $isLoadErrorPresented
            ) {
                Button("settings.security.load.retry", action: UniHaptic.action(onRetry))
                Button("common.cancel", role: .cancel, action: UniHaptic.action {})
            } message: {
                Text("settings.security.load.error.message")
            }
    }
}

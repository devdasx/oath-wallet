import SwiftUI

@MainActor
struct OnboardingView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.walletAppLockIsPresented) private var isAppLockPresented
    let database: WalletDatabase
    let startAction: OnboardingStartAction?
    let usesExistingProfileSecurity: Bool
    let onPrepareWalletForOpen: ((String) async -> Bool)?
    let onOpenWallet: (String) -> Void

    @State private var navigationPath: [OnboardingDestination] = []
    @State private var presentedSheet: OnboardingSheet?
    @State private var pendingDeviceMigrationInvitation: DeviceMigrationInvitation?
    @State private var physicalEntropyCreationSession:
        OnboardingPhysicalEntropyCreationSession?
    @State private var creationDraft: WalletCreationDraft?
    @State private var confirmedPasscode = ""
    @State private var enablesBiometricUnlock = false
    @State private var importDraft: WalletImportDraft?
    @State private var restoredWalletName: String?
    @State private var restoredCloudBackupIdentity:
        WalletCloudBackupRemoteIdentity?
    @State private var selectedTrustWalletBackup:
        TrustWalletBackupDescriptor?
    @State private var createdWalletAddress: String?
    @State private var createdWalletID: String?
    @State private var successAllowsManualBackup = true
    @State private var walletPreparation: OnboardingWalletPreparation?
    @State private var creationErrorMessage: String?
    @State private var didApplyStartAction = false
    @State private var walletCreationTask: Task<Void, Never>?
    @State private var walletPersistenceTask: Task<Void, Never>?
    @State private var importEligibilityTask: Task<Void, Never>?
    @State private var pendingImportEligibility:
        PendingWalletImportEligibility?
    @State private var importEligibilityNavigationPath:
        [OnboardingDestination]?
    @State private var importEligibilityErrorPresented = false
    @State private var duplicateImportActionTask: Task<Void, Never>?
    @State private var duplicateImportActionError: String?
    @State private var duplicateImportCompletion =
        WalletSetupSheetCompletion()

    init(
        database: WalletDatabase,
        startAction: OnboardingStartAction? = nil,
        usesExistingProfileSecurity: Bool = false,
        onPrepareWalletForOpen: ((String) async -> Bool)? = nil,
        onOpenWallet: @escaping (String) -> Void = { _ in }
    ) {
        self.database = database
        self.startAction = startAction
        self.usesExistingProfileSecurity = usesExistingProfileSecurity
        self.onPrepareWalletForOpen = onPrepareWalletForOpen
        self.onOpenWallet = onOpenWallet
    }
    var body: some View {
        NavigationStack(path: ($navigationPath)) {
            flowRoot
            .navigationDestination(for: OnboardingDestination.self) { destination in
                switch destination {
                case .creationPasscode:
                    PINSetupFlowView {
                        await completePasscodeSetup(
                            $0,
                            completion: .persistCreatedWallet
                        )
                    }
                case let .creationFailure(failure):
                    WalletCreationPersistenceFailureView(
                        failure: failure,
                        isRetrying: walletPersistenceTask != nil,
                        onRetry: retryCreatedWalletPreparation,
                        onCancel: {
                            creationDraft = nil
                            walletPreparation = nil
                            confirmedPasscode = ""
                            navigationPath = []
                        }
                    )
                case let .physicalEntropy(destination):
                    physicalEntropyDestination(destination)
                case .importPasscode:
                    OnboardingImportPasscodeScreen {
                        await completePasscodeSetup(
                            $0,
                            completion: .persistImportedWallet
                        )
                    }
                case let .importFailure(failure):
                    WalletImportPersistenceFailureView(
                        failure: failure,
                        isRetrying: false,
                        onRetry: retryImportedWalletPersistence,
                        onCancel: {
                            importDraft = nil
                            restoredWalletName = nil
                            restoredCloudBackupIdentity = nil
                            walletPreparation = nil
                            confirmedPasscode = ""
                            navigationPath = []
                        }
                    )
                case .importOptions:
                    importOptionsScreen
                case let .importCredential(credential):
                    ImportWalletCredentialView(
                        credential: credential,
                        onImport: handleImportedDraft
                    )
                    .allowsHitTesting(walletPersistenceTask == nil)
                    .navigationBarBackButtonHidden(
                        walletPersistenceTask != nil
                    )
                case .privateKeyNetworkSelection:
                    PrivateKeyNetworkSelectionView(
                        networks: PrivateKeyImportNetwork.allCases
                    )
                case let .privateKeyCredential(network):
                    PrivateKeyCredentialView(
                        network: network,
                        onImport: handleImportedDraft
                    )
                    .allowsHitTesting(walletPersistenceTask == nil)
                    .navigationBarBackButtonHidden(
                        walletPersistenceTask != nil
                    )
                case .muunRecoveryMethods:
                    OnboardingMuunRecoveryMethodScreen(
                        onEmergencyKit: {
                            navigationPath.append(.muunEmergencyKit)
                        },
                        onEncryptedKeys: {
                            navigationPath.append(.muunEncryptedKeys)
                        }
                    )
                case .muunEmergencyKit:
                    OnboardingMuunEmergencyKitImportScreen(
                        onImport: handleImportedDraft
                    )
                case .muunEncryptedKeys:
                    OnboardingMuunEncryptedKeysImportScreen(
                        onImport: handleImportedDraft
                    )
                case .trustWalletPassword:
                    if let backup = selectedTrustWalletBackup {
                        OnboardingTrustWalletPasswordScreen(
                            backup: backup,
                            onRestore: handleTrustWalletRestore
                        )
                    }
                case .restoreICloud:
                    iCloudRestoreScreen
                case let .deviceMigrationImport(invitation):
                    DeviceMigrationImportScreen(
                        invitation: invitation,
                        database: database
                    ) { identity in
                        onOpenWallet(identity.address)
                    }
                case .walletReady:
                    WalletSuccessView(
                        kind: successKind,
                        isReady: createdWalletAddress != nil,
                        backupContext: createdWalletID.map {
                            WalletSuccessBackupContext(database: database, walletID: $0)
                        },
                        allowsManualBackup: successAllowsManualBackup,
                        onPrepare: startWalletPreparation,
                        onContinue: openReadyWallet
                    )
                }
            }
        }
        .interactiveDismissDisabled(
            (walletPersistenceTask != nil && createdWalletAddress == nil)
                || (physicalEntropyCreationSession?.isPersistingWallet == true
                    && physicalEntropyCreationSession?.createdWalletAddress == nil)
        )
        .sheet(
            item: $presentedSheet,
            onDismiss: onboardingSheetDidDismiss
        ) { sheet in
            switch sheet {
            case .deviceMigrationScanner:
                NavigationStack {
                    Group {
                        DeviceMigrationScannerScreen { invitation in
                            pendingDeviceMigrationInvitation = invitation
                            presentedSheet = nil
                        }
                    }

                }
                .walletScannerPresentation()
            case let .walletSetup(route):
                WalletSetupSheet(route: route)
                    .walletSheetPresentation()
                    .presentationDragIndicator(.visible)
                    .presentationDetents([.medium, .large])
            case let .duplicateImport(warning):
                NavigationStack {
                    Group {
                        DuplicateWalletImportWarningSheet(
                            warning: warning,
                            isProcessing: duplicateImportActionTask != nil,
                            errorMessage: duplicateImportActionError,
                            onOpenOrActivate: activateOrOpenDuplicateWallet,
                            onChooseDifferent: chooseDifferentImport
                        )
                    }

                }
                .walletSheetPresentation()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
            case let .unsafeCredential(warning):
                UnsafeCredentialImportWarningSheet(
                    warning: warning,
                    onChooseDifferent: chooseDifferentUnsafeCredential
                )
            }
        }
        .alert(
            "import.duplicate.lookup.error.title",
            isPresented: $importEligibilityErrorPresented
        ) {
            Button("common.cancel", role: .cancel, action: UniHaptic.action {
                cancelPendingImportEligibility()
            })
            Button("common.try_again", action: UniHaptic.action {
                retryPendingImportEligibility()
            })
        } message: {
            Text("import.duplicate.lookup.error.message")
        }
        .onChange(of: navigationPath) { _, path in
            if let expectedPath = importEligibilityNavigationPath,
               expectedPath != path {
                cancelPendingImportEligibility()
            }
            endPhysicalEntropyCreationIfNeeded(for: path)
            if !path.contains(.trustWalletPassword) {
                selectedTrustWalletBackup = nil
            }
            guard path.isEmpty else { return }
            creationDraft = nil
            confirmedPasscode = ""
            enablesBiometricUnlock = false
            importDraft = nil
            restoredWalletName = nil
            restoredCloudBackupIdentity = nil
            createdWalletAddress = nil
            createdWalletID = nil
            walletPersistenceTask?.cancel()
            walletPersistenceTask = nil
        }
        .onDisappear {
            // A native lock cover temporarily hides the flow without ending it.
            guard scenePhase == .active, !isAppLockPresented else { return }
            walletCreationTask?.cancel()
            walletPersistenceTask?.cancel()
            walletPersistenceTask = nil
            importEligibilityTask?.cancel()
            importEligibilityTask = nil
            duplicateImportActionTask?.cancel()
            duplicateImportActionTask = nil
            // Backup authentication can temporarily cover a completed flow.
            if physicalEntropyCreationSession?.createdWalletAddress == nil {
                physicalEntropyCreationSession?.cancelOwnedWork()
                physicalEntropyCreationSession = nil
            }
        }
        .task {
            guard !didApplyStartAction else { return }
            didApplyStartAction = true

            if startAction == .createWallet {
                beginWalletCreation()
            } else if startAction == .physicalEntropy {
                beginPhysicalEntropyCreation()
            }
        }
    }

    @ViewBuilder
    private var flowRoot: some View {
        switch startAction {
        case .some(.importWallet):
            importOptionsScreen
        case .some(.restoreICloud):
            iCloudRestoreScreen
        case .some(.createWallet):
            quickWalletCreationRoot
        case .some(.physicalEntropy):
            quickWalletCreationRoot
        case .none:
            onboardingRoot
        }
    }

    private var quickWalletCreationRoot: some View {
        List {
            Group {
                Section {
                    if let creationErrorMessage {
                        Text(verbatim: creationErrorMessage)
                            .foregroundStyle(WalletTheme.danger)

                        Button("common.try_again", action: UniHaptic.action(beginWalletCreation))
                    } else {
                        Text("wallet.launch.loading.accessibility")
                            .foregroundStyle(WalletTheme.secondaryLabel)
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("settings.wallets.create")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var onboardingRoot: some View {
        OnboardingWelcomeView(
            creationErrorMessage: creationErrorMessage,
            onCreateWallet: beginWalletCreation,
            onImportWallet: {
                navigationPath.append(.importOptions)
            }
        )
    }

    private var importOptionsScreen: some View {
        ImportWalletOptionsView(
            onRecoveryPhrase: {
                navigationPath.append(
                    .importCredential(.recoveryPhrase)
                )
            },
            onPrivateKey: {
                navigationPath.append(.privateKeyNetworkSelection)
            },
            onPhysicalEntropy: beginPhysicalEntropyCreation,
            onRestoreICloud: {
                navigationPath.append(.restoreICloud)
            },
            onTransferFromIPhone: usesExistingProfileSecurity
                ? nil
                : {
                    pendingDeviceMigrationInvitation = nil
                    presentedSheet = .deviceMigrationScanner
                },
            onMuunRecovery: {
                navigationPath.append(.muunRecoveryMethods)
            },
            onTrustWalletRestore: { backup in
                selectedTrustWalletBackup = backup
                navigationPath.append(.trustWalletPassword)
            }
        )
    }

    @MainActor
    private func handleImportedDraft(_ draft: WalletImportDraft) {
        beginImportEligibilityCheck(
            PendingWalletImportEligibility(
                draft: draft,
                walletName: nil,
                cloudBackupIdentity: nil
            )
        )
    }

    private var successKind: WalletSuccessKind {
        if case .creation = walletPreparation { return .created }
        let restored = navigationPath.contains { destination in
            switch destination {
            case .restoreICloud, .trustWalletPassword, .muunEmergencyKit, .muunEncryptedKeys:
                true
            default:
                false
            }
        }
        return restored ? .restored : .imported
    }

    @MainActor
    private func handleTrustWalletRestore(
        _ draft: WalletImportDraft,
        walletName: String?
    ) {
        beginImportEligibilityCheck(
            PendingWalletImportEligibility(
                draft: draft,
                walletName: walletName,
                cloudBackupIdentity: nil
            )
        )
    }

    private var iCloudRestoreScreen: some View {
        ICloudWalletRestoreView(database: database) {
            draft,
            walletName,
            cloudBackupIdentity in
            beginImportEligibilityCheck(
                PendingWalletImportEligibility(
                    draft: draft,
                    walletName: walletName,
                    cloudBackupIdentity: cloudBackupIdentity
                )
            )
        }
        .allowsHitTesting(walletPersistenceTask == nil)
        .navigationBarBackButtonHidden(walletPersistenceTask != nil)
    }

    @MainActor
    private func beginImportEligibilityCheck(
        _ pendingImport: PendingWalletImportEligibility
    ) {
        if let finding = WalletCredentialSafetyService.finding(
            for: pendingImport.draft
        ) {
            cancelPendingImportEligibility()
            presentedSheet = .unsafeCredential(
                UnsafeCredentialImportWarning(finding: finding)
            )
            return
        }

        importEligibilityTask?.cancel()
        pendingImportEligibility = pendingImport
        importEligibilityNavigationPath = navigationPath
        importEligibilityErrorPresented = false
        duplicateImportActionError = nil

        importEligibilityTask = Task { @MainActor in
            defer { importEligibilityTask = nil }

            do {
                let existingWallet = try await database.existingWallet(
                    matching: pendingImport.draft
                )
                try Task.checkCancellation()
                guard importEligibilityNavigationPath == navigationPath else {
                    return
                }

                pendingImportEligibility = nil
                importEligibilityNavigationPath = nil
                if let existingWallet {
                    presentedSheet = .duplicateImport(
                        DuplicateWalletImportWarning(
                            wallet: existingWallet
                        )
                    )
                } else {
                    continueImportedWallet(pendingImport)
                }
            } catch is CancellationError {
                return
            } catch {
                UniHaptic.play(.error)
                importEligibilityErrorPresented = true
            }
        }
    }

    @MainActor
    private func continueImportedWallet(
        _ pendingImport: PendingWalletImportEligibility
    ) {
        importDraft = pendingImport.draft
        successAllowsManualBackup = pendingImport.draft.hasRecoveryPhrase
        restoredWalletName = pendingImport.walletName
        restoredCloudBackupIdentity = pendingImport.cloudBackupIdentity
        createdWalletAddress = nil
        createdWalletID = nil
        walletPreparation = .imported
        if !usesExistingProfileSecurity {
            confirmedPasscode = ""
        }
        push(
            OnboardingImportPersistenceEntry.destination(
                usesExistingProfileSecurity: usesExistingProfileSecurity
            )
        )
    }

    @MainActor
    private func retryPendingImportEligibility() {
        guard let pendingImportEligibility else { return }
        beginImportEligibilityCheck(pendingImportEligibility)
    }

    @MainActor
    private func cancelPendingImportEligibility() {
        importEligibilityTask?.cancel()
        importEligibilityTask = nil
        pendingImportEligibility = nil
        importEligibilityNavigationPath = nil
        importEligibilityErrorPresented = false
    }

    @MainActor
    private func activateOrOpenDuplicateWallet() {
        guard duplicateImportActionTask == nil,
              case let .duplicateImport(warning) = presentedSheet
        else {
            return
        }

        duplicateImportActionError = nil
        duplicateImportActionTask = Task { @MainActor in
            defer { duplicateImportActionTask = nil }

            do {
                let address: String
                if warning.wallet.isSelected {
                    address = warning.wallet.address
                } else {
                    let identity = try await database.selectWallet(
                        walletID: warning.wallet.id
                    )
                    address = identity.address
                    PushNotificationCoordinator.shared
                        .walletDataDidChange()
                }
                try Task.checkCancellation()
                guard duplicateImportCompletion.queue(
                    walletAddress: address
                ) else {
                    throw WalletManagementError.addressUnavailable
                }

                UniHaptic.play(.successQuiet)
                presentedSheet = nil
            } catch is CancellationError {
                return
            } catch {
                UniHaptic.play(.error)
                duplicateImportActionError = WalletLocalization.string(
                    "import.duplicate.activation.error"
                )
            }
        }
    }

    @MainActor
    private func chooseDifferentImport() {
        duplicateImportCompletion.cancel()
        duplicateImportActionError = nil
        presentedSheet = nil
    }

    @MainActor
    private func chooseDifferentUnsafeCredential() {
        cancelPendingImportEligibility()
        selectedTrustWalletBackup = nil
        presentedSheet = nil
        if let index = navigationPath.lastIndex(of: .importOptions) {
            navigationPath = Array(navigationPath.prefix(through: index))
        } else {
            navigationPath = [.importOptions]
        }
    }

    @MainActor
    private func onboardingSheetDidDismiss() {
        finishDuplicateImportActivation()
        guard let invitation = pendingDeviceMigrationInvitation else { return }
        pendingDeviceMigrationInvitation = nil
        navigationPath.append(.deviceMigrationImport(invitation))
    }

    @MainActor
    private func finishDuplicateImportActivation() {
        guard let address = duplicateImportCompletion
            .consumeAfterSheetDismissal() else {
            duplicateImportActionError = nil
            return
        }

        importDraft = nil
        restoredWalletName = nil
        restoredCloudBackupIdentity = nil
        selectedTrustWalletBackup = nil
        confirmedPasscode = ""
        enablesBiometricUnlock = false
        navigationPath = []
        duplicateImportActionError = nil
        onOpenWallet(address)
    }

    @MainActor
    private func beginPhysicalEntropyCreation() {
        guard physicalEntropyCreationSession == nil else { return }
        physicalEntropyCreationSession =
            OnboardingPhysicalEntropyCreationSession(
                database: database,
                usesExistingProfileSecurity: usesExistingProfileSecurity,
                onPrepareWalletForOpen: onPrepareWalletForOpen
            )
        navigationPath.append(
            .physicalEntropy(
                OnboardingPhysicalEntropyNavigation.initialDestination
            )
        )
    }

    @ViewBuilder
    private func physicalEntropyDestination(
        _ destination: OnboardingPhysicalEntropyDestination
    ) -> some View {
        if let physicalEntropyCreationSession {
            OnboardingPhysicalEntropyCreationFlow(
                destination: destination,
                session: physicalEntropyCreationSession,
                onNavigate: navigateWithinPhysicalEntropyCreation,
                onReturnToRecoveryPhrase:
                    returnPhysicalEntropyCreationToRecoveryPhrase,
                onCompleted: completePhysicalEntropyCreation
            )
        }
    }

    @MainActor
    private func navigateWithinPhysicalEntropyCreation(
        _ destination: OnboardingPhysicalEntropyDestination
    ) {
        guard physicalEntropyCreationSession != nil else { return }
        let route = OnboardingDestination.physicalEntropy(destination)
        if let last = navigationPath.last {
            switch (last, destination) {
            case (.physicalEntropy(.success), .persistenceFailure),
                 (.physicalEntropy(.persistenceFailure), .success):
                navigationPath[navigationPath.count - 1] = route
                return
            default:
                break
            }
        }
        push(route)
    }

    @MainActor
    private func returnPhysicalEntropyCreationToRecoveryPhrase() {
        guard let firstFlowIndex = navigationPath.firstIndex(
            where: \.isPhysicalEntropyDestination
        ) else {
            return
        }
        navigationPath = Array(navigationPath[..<firstFlowIndex]) + [
            .physicalEntropy(.recoveryPhrase)
        ]
    }

    @MainActor
    private func completePhysicalEntropyCreation(_ address: String) {
        guard !address.isEmpty else { return }
        physicalEntropyCreationSession?.cancelOwnedWork()
        physicalEntropyCreationSession = nil
        onOpenWallet(address)
    }

    @MainActor
    private func endPhysicalEntropyCreationIfNeeded(
        for path: [OnboardingDestination]
    ) {
        guard let physicalEntropyCreationSession,
              !path.contains(where: \.isPhysicalEntropyDestination) else {
            return
        }
        physicalEntropyCreationSession.cancelOwnedWork()
        self.physicalEntropyCreationSession = nil
    }

    private func beginWalletCreation() {
        let sourcePath = navigationPath
        guard walletCreationTask == nil,
              sourcePath.isEmpty,
              presentedSheet == nil,
              physicalEntropyCreationSession == nil else { return }
        walletCreationTask = Task { @MainActor in
            defer { walletCreationTask = nil }
            do {
                let draft = try await Task.detached(
                    priority: .userInitiated
                ) {
                    try WalletCoreService.generateEVMWallet()
                }.value
                try Task.checkCancellation()
                guard navigationPath == sourcePath,
                      presentedSheet == nil else {
                    return
                }
                creationDraft = draft
                successAllowsManualBackup = true
                walletPreparation = .creation
                confirmedPasscode = ""
                enablesBiometricUnlock = false
                createdWalletAddress = nil
                createdWalletID = nil
                creationErrorMessage = nil
                if usesExistingProfileSecurity {
                    push(.walletReady)
                } else {
                    push(.creationPasscode)
                }
            } catch is CancellationError {
                return
            } catch {
                UniHaptic.play(.error)
                creationErrorMessage = WalletLocalization.string(
                    "wallet.creation.generate.error"
                )
            }
        }
    }

    private func persistCreatedWallet() async throws -> String {
        guard let creationDraft else {
            throw WalletCreationPersistenceError.invalidDraft
        }
        guard usesExistingProfileSecurity || !confirmedPasscode.isEmpty else {
            throw WalletCreationPersistenceError.invalidDraft
        }

        let identity = try await WalletPersistenceWorker.shared
            .persistCreatedWallet(
                database: database,
                draft: creationDraft,
                security: walletPersistenceSecurity
            )

        PushNotificationCoordinator.shared.walletDataDidChange()
        confirmedPasscode = ""
        createdWalletID = identity.walletID
        return identity.address
    }
    @MainActor
    private func startWalletPreparation() {
        guard walletPersistenceTask == nil else { return }
        guard createdWalletAddress == nil,
              let walletPreparation else { return }

        walletPersistenceTask = Task { @MainActor in
            defer { walletPersistenceTask = nil }

            do {
                let address: String
                switch walletPreparation {
                case .creation:
                    address = try await persistCreatedWallet()
                case .imported:
                    address = try await persistImportedWallet()
                }
                // Publish the durable result before handing off to Home. The
                // root owns loading; dismissing this sheet cannot undo the save.
                if usesExistingProfileSecurity { createdWalletAddress = address }
                if let onPrepareWalletForOpen {
                    _ = await onPrepareWalletForOpen(address)
                }
                try Task.checkCancellation()
                createdWalletAddress = address
            } catch is CancellationError {
                return
            } catch {
                UniHaptic.play(.error)
                routeWalletPreparationFailure(
                    WalletPersistenceFailure(error: error),
                    preparation: walletPreparation
                )
            }
        }
    }

    private func persistImportedWallet() async throws -> String {
        guard let importDraft else {
            throw WalletCreationPersistenceError.invalidDraft
        }
        guard usesExistingProfileSecurity || !confirmedPasscode.isEmpty else {
            throw WalletCreationPersistenceError.invalidDraft
        }

        let preferredWalletName: String?
        if let restoredWalletName {
            guard let normalizedWalletName =
                WalletDefaultName.normalizedCustomName(
                    restoredWalletName
                )
            else {
                throw WalletCreationPersistenceError.invalidDraft
            }
            preferredWalletName =
                WalletDefaultName.isLegacyGenericName(
                    normalizedWalletName
                )
                ? nil
                : normalizedWalletName
        } else {
            preferredWalletName = nil
        }

        let identity = try await WalletPersistenceWorker.shared
            .persistImportedWallet(
                database: database,
                draft: importDraft,
                security: walletPersistenceSecurity,
                preferredWalletName: preferredWalletName,
                cloudBackupIdentity: restoredCloudBackupIdentity
            )
        PushNotificationCoordinator.shared.walletDataDidChange()
        self.importDraft = nil
        self.restoredWalletName = nil
        self.restoredCloudBackupIdentity = nil
        confirmedPasscode = ""
        createdWalletID = identity.walletID
        return identity.address
    }
    @MainActor
    private func retryCreatedWalletPreparation() {
        guard creationDraft != nil else { return }
        successAllowsManualBackup = true
        walletPreparation = .creation
        replaceFailureWithWalletReady()
    }

    @MainActor
    private func retryImportedWalletPersistence() {
        guard importDraft != nil else { return }
        walletPreparation = .imported
        replaceFailureWithWalletReady()
    }

    private var walletPersistenceSecurity: WalletPersistenceSecurity {
        if usesExistingProfileSecurity {
            return .reuseExistingProfile
        }
        return .establishOrVerify(
            passcode: confirmedPasscode,
            biometricEnabled: enablesBiometricUnlock
        )
    }

    @MainActor
    private func completePasscodeSetup(
        _ passcode: String,
        completion: OnboardingPasscodeCompletion
    ) async {
        guard navigationPath.last == completion.destination else { return }
        let biometricUnlock = await authenticateBiometricsIfAvailable()
        do { try await WalletAuthenticationPresentationReadiness().wait() }
        catch { return }
        guard !Task.isCancelled,
              navigationPath.last == completion.destination else { return }

        confirmedPasscode = passcode
        enablesBiometricUnlock = biometricUnlock
        switch completion {
        case .persistCreatedWallet:
            successAllowsManualBackup = true
            walletPreparation = .creation
            push(.walletReady)
        case .persistImportedWallet:
            walletPreparation = .imported
            push(.walletReady)
        }
    }

    @MainActor
    private func authenticateBiometricsIfAvailable() async -> Bool {
        let authenticator = WalletBiometricAuthenticator.shared
        guard authenticator.availability().isAvailable else {
            return false
        }

        do {
            try await authenticator.authenticate(
                reason: WalletLocalization.string(
                    "settings.security.biometrics.enable.reason"
                )
            )
            return true
        } catch {
            return false
        }
    }

    private func openReadyWallet() {
        guard let walletAddress = createdWalletAddress,
              !walletAddress.isEmpty else {
            return
        }
        clearWalletReadyInputs()
        onOpenWallet(walletAddress)
    }

    private func clearWalletReadyInputs() {
        creationDraft = nil
        importDraft = nil
        restoredWalletName = nil
        restoredCloudBackupIdentity = nil
        selectedTrustWalletBackup = nil
        walletPreparation = nil
        confirmedPasscode = ""
        enablesBiometricUnlock = false
    }

    private func routeWalletPreparationFailure(
        _ failure: WalletPersistenceFailure,
        preparation: OnboardingWalletPreparation
    ) {
        let destination: OnboardingDestination = switch preparation {
        case .creation:
            .creationFailure(failure)
        case .imported:
            .importFailure(failure)
        }
        if let last = navigationPath.last, last == .walletReady {
            navigationPath[navigationPath.count - 1] = destination
        } else {
            push(destination)
        }
    }

    private func replaceFailureWithWalletReady() {
        if let last = navigationPath.last {
            switch last {
            case .creationFailure, .importFailure:
                navigationPath[navigationPath.count - 1] = .walletReady
                return
            default:
                break
            }
        }
        push(.walletReady)
    }

    private func push(_ destination: OnboardingDestination) {
        navigationPath = OnboardingNavigationTransition.pushing(
            destination,
            onto: navigationPath
        )
    }
}

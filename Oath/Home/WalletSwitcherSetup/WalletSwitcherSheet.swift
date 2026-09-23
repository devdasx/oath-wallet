import SwiftUI

/// The switcher and every add-wallet step share this one presentation and
/// navigation stack. Home's independent + sheet does not participate.
struct WalletSwitcherSheet<SettingsDestination: View>: View {
    let database: WalletDatabase
    let isAppSwitcherPrivacyActive: Bool
    let refreshGeneration: UUID
    @Binding var path: [WalletSwitcherNavigationRoute]
    let onWalletSelected: (ManagedWallet, String) async -> Bool
    let onWalletAdded: (String) async -> Bool
    let onDismissRequested: () -> Void
    let settingsDestination: (String) -> SettingsDestination

    @State private var session: WalletSwitcherSetupSession
    @State private var importTask: Task<Void, Never>?
    @State private var commitTask: Task<Void, Never>?
    @State private var completionTask: Task<Void, Never>?
    @State private var commitFailure: WalletPersistenceFailure?
    @State private var selectedTrustWalletBackup:
        TrustWalletBackupDescriptor?
    @State private var unsafeCredentialWarning:
        UnsafeCredentialImportWarning?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.walletAppLockIsPresented) private var isAppLockPresented
    private let makeCloudDiscovery: () -> WalletSwitcherICloudDiscoveryModel

    init(
        database: WalletDatabase,
        isAppSwitcherPrivacyActive: Bool,
        refreshGeneration: UUID,
        path: Binding<[WalletSwitcherNavigationRoute]>,
        onWalletSelected: @escaping (ManagedWallet, String) async -> Bool,
        onWalletAdded: @escaping (String) async -> Bool,
        onDismissRequested: @escaping () -> Void,
        services: WalletSwitcherSetupServices? = nil,
        makeCloudDiscovery: @escaping () -> WalletSwitcherICloudDiscoveryModel = {
            WalletSwitcherICloudDiscoveryModel()
        },
        @ViewBuilder settingsDestination: @escaping (String) -> SettingsDestination
    ) {
        self.database = database
        self.isAppSwitcherPrivacyActive = isAppSwitcherPrivacyActive
        self.refreshGeneration = refreshGeneration
        _path = path
        self.onWalletSelected = onWalletSelected
        self.onWalletAdded = onWalletAdded
        self.onDismissRequested = onDismissRequested
        self.settingsDestination = settingsDestination
        self.makeCloudDiscovery = makeCloudDiscovery
        _session = State(initialValue: WalletSwitcherSetupSession(
            services: services ?? .live(database: database)
        ))
    }

    var body: some View {
        NavigationStack(path: ($path)) {
            WalletSwitcherView(
                database: database,
                isAppSwitcherPrivacyActive: isAppSwitcherPrivacyActive,
                refreshGeneration: refreshGeneration,
                onWalletSelected: onWalletSelected,
                onWalletSettingsRequested: {
                    path.append(.settings(walletID: $0.id))
                },
                onAddWalletRequested: begin,
                onDismissRequested: onDismissRequested
            )
            .navigationDestination(for: WalletSwitcherNavigationRoute.self) { route in
                switch route {
                case let .settings(walletID):
                    settingsDestination(walletID)
                case let .setup(step):
                    setupDestination(step)
                }
            }
        }
        .interactiveDismissDisabled(
            session.isCommitting
                || session.isFinishing
                || completionTask != nil
        )
        .onChange(of: path) { previous, current in
            guard current.count < previous.count else { return }
            importTask?.cancel()
            commitTask?.cancel()
            completionTask?.cancel()
            commitFailure = nil
            session.didNavigateBack(to: current.compactMap {
                if case let .setup(step) = $0 { return step }
                return nil
            })
            let setupSteps = current.compactMap {
                if case let .setup(step) = $0 { return step }
                return nil
            }
            if !setupSteps.contains(.trustWalletPassword) {
                selectedTrustWalletBackup = nil
            }
        }
        .onDisappear {
            guard scenePhase == .active, !isAppLockPresented else { return }
            importTask?.cancel()
            commitTask?.cancel()
            completionTask?.cancel()
            selectedTrustWalletBackup = nil
            unsafeCredentialWarning = nil
        }
        .sheet(item: $unsafeCredentialWarning) { warning in
            WalletSwitcherUnsafeCredentialWarningScreen(
                warning: warning,
                onChooseDifferent: chooseDifferentUnsafeCredential
            )
        }
        .alert("import.saving.error.title", isPresented: Binding(
            get: { session.importFailure != nil },
            set: { if !$0 { session.importFailure = nil } }
        )) {
            Button("common.ok", role: .cancel, action: UniHaptic.action {})
        } message: {
            if let failure = session.importFailure {
                Text(LocalizedStringKey(failure.messageKey))
                Text(verbatim: failure.diagnosticCode)
            }
        }
        .alert(
            "import.saving.error.title",
            isPresented: Binding(
                get: { commitFailure != nil },
                set: { if !$0 { commitFailure = nil } }
            )
        ) {
            Button("import.saving.retry", action: UniHaptic.action(commitCurrentSetup))

            if let supportURL = commitFailure?.supportURL {
                Button("wallet.persistence.contact_support", action: UniHaptic.action(nil) {
                    openURL(supportURL)
                })
            }

            Button("common.cancel", role: .cancel, action: UniHaptic.action {
                cancelFailedCommit()
            })
        } message: {
            if let commitFailure {
                Text(verbatim: persistenceFailureMessage(commitFailure))
            }
        }
        .alert("settings.wallets.select.error", isPresented: $session.completionFailed) {
            Button("common.ok", role: .cancel, action: UniHaptic.action {})
        }
    }

    @ViewBuilder
    private func setupDestination(_ step: WalletSwitcherSetupRoute) -> some View {
        switch step {
        case .recovery:
            WalletSwitcherRecoveryScreen(
                words: session.creationDraft?.words ?? [],
                hasPassphrase: !(session.creationDraft?.passphrase.isEmpty ?? true),
                isSaving: session.isCommitting,
                generationFailure: session.generationFailure,
                onPrepare: session.prepareCreation,
                onManagePassphrase: { push(.creationPassphrase) },
                onViewWordList: { push(.wordList(.english)) },
                onContinue: showSetupSuccess
            )
        case .creationPassphrase:
            WalletSwitcherCreationPassphraseScreen(
                initialPassphrase: session.creationDraft?.passphrase ?? "",
                onSave: session.applyPassphrase
            )
        case let .wordList(language):
            WalletSwitcherWordListScreen(initialLanguage: language)
        case .importOptions:
            WalletSwitcherImportOptionsScreen(
                onRecoveryPhrase: { push(.importRecoveryPhrase) },
                onPrivateKey: { push(.privateKeyNetworks) },
                onPhysicalEntropy: { push(.physicalEntropy) },
                onRestoreICloud: { push(.restoreICloud) },
                onTransferFromIPhone: nil,
                onMuunRecovery: { push(.muunRecoveryMethods) },
                onTrustWalletRestore: { backup in
                    selectedTrustWalletBackup = backup
                    push(.trustWalletPassword)
                }
            )
        case .importRecoveryPhrase:
            WalletSwitcherRecoveryImportScreen(
                credential: .recoveryPhrase,
                onImport: { prepareImport($0) }
            )
            .disabled(session.isCheckingImport || session.isCommitting)
            .navigationBarBackButtonHidden(session.isCommitting)
        case .privateKeyNetworks:
            WalletSwitcherPrivateKeyNetworkScreen()
        case let .privateKeyCredential(network):
            WalletSwitcherPrivateKeyImportScreen(
                network: network,
                onImport: { prepareImport($0) }
            )
            .disabled(session.isCheckingImport || session.isCommitting)
            .navigationBarBackButtonHidden(session.isCommitting)
        case .muunRecoveryMethods:
            WalletSwitcherMuunRecoveryMethodScreen(
                onEmergencyKit: { push(.muunEmergencyKit) },
                onEncryptedKeys: { push(.muunEncryptedKeys) }
            )
        case .muunEmergencyKit:
            WalletSwitcherMuunEmergencyKitImportScreen(
                onImport: { prepareImport($0) }
            )
            .disabled(session.isCheckingImport || session.isCommitting)
            .navigationBarBackButtonHidden(session.isCommitting)
        case .muunEncryptedKeys:
            WalletSwitcherMuunEncryptedKeysImportScreen(
                onImport: { prepareImport($0) }
            )
            .disabled(session.isCheckingImport || session.isCommitting)
            .navigationBarBackButtonHidden(session.isCommitting)
        case .trustWalletPassword:
            if let backup = selectedTrustWalletBackup {
                WalletSwitcherTrustWalletPasswordScreen(
                    backup: backup
                ) { draft, name in
                    prepareImport(draft, name: name)
                }
                .disabled(session.isCheckingImport || session.isCommitting)
                .navigationBarBackButtonHidden(session.isCommitting)
            }
        case .physicalEntropy:
            WalletSwitcherEntropyScreen(
                isGeneratingWallet: false,
                errorMessage: nil,
                onComplete: { entropy in
                    session.beginCreation(entropy: entropy)
                    push(.recovery)
                }
            )
        case .restoreICloud:
            WalletSwitcherICloudRestoreScreen(
                database: database, discovery: makeCloudDiscovery()
            )
        case let .restoreBackup(backup):
            WalletSwitcherICloudBackupScreen(
                walletID: backup.walletID,
                walletName: backup.walletName,
                backedUpAt: backup.backedUpAt,
                hasPassphrase: backup.hasPassphrase,
                onRestore: { prepareImport($0, name: $1, cloudIdentity: $2) }
            )
            .disabled(session.isCheckingImport || session.isCommitting)
            .navigationBarBackButtonHidden(session.isCommitting)
        case .duplicateImport:
            if let duplicate = session.duplicate {
                WalletSwitcherDuplicateImportScreen(
                    warning: duplicate,
                    isProcessing: session.isFinishing,
                    errorMessage: nil,
                    onOpenOrActivate: finish,
                    onChooseDifferent: { path.removeLast() }
                )
                .navigationBarBackButtonHidden(session.isFinishing)
            }
        case .success:
            WalletSwitcherSetupSuccessScreen(
                kind: successKind,
                isReady: session.isReady,
                backupContext: session.identity.map {
                    WalletSuccessBackupContext(database: database, walletID: $0.walletID)
                },
                allowsManualBackup: session.allowsManualBackup,
                canFinish: session.identity != nil
                    && !session.isFinishing
                    && completionTask == nil,
                isFinishing: session.isFinishing || completionTask != nil,
                onPrepare: commitCurrentSetup,
                onDone: finish
            )
        }
    }

    private func begin(_ action: HomeWalletAddAction) {
        guard path.isEmpty else { return }
        if action == .create {
            session.beginCreation()
        } else {
            session.reset()
        }
        push(.entry(for: action))
    }

    private var successKind: WalletSuccessKind {
        let routes = path.compactMap { route -> WalletSwitcherSetupRoute? in
            if case let .setup(step) = route { return step }
            return nil
        }
        if routes.contains(.recovery) || routes.contains(.physicalEntropy) { return .created }
        let restored = routes.contains { route in
            switch route {
            case .restoreICloud, .restoreBackup, .trustWalletPassword, .muunEmergencyKit, .muunEncryptedKeys:
                true
            default:
                false
            }
        }
        return restored ? .restored : .imported
    }

    private func push(_ step: WalletSwitcherSetupRoute) {
        path.append(.setup(step))
    }

    private func prepareImport(
        _ draft: WalletImportDraft,
        name: String? = nil,
        cloudIdentity: WalletCloudBackupRemoteIdentity? = nil
    ) {
        guard !session.isCheckingImport else { return }
        if let finding = WalletCredentialSafetyService.finding(for: draft) {
            unsafeCredentialWarning = UnsafeCredentialImportWarning(
                finding: finding
            )
            return
        }
        let sourcePath = path
        importTask?.cancel()
        importTask = Task { @MainActor in
            let step = await session.prepareImport(
                draft, restoredName: name, cloudIdentity: cloudIdentity
            )
            guard !Task.isCancelled, path == sourcePath, let step else { return }
            push(step.destination)
        }
    }

    private func commitCurrentSetup() {
        startCommit(from: path)
    }

    private func showSetupSuccess() {
        guard !session.isCommitting,
              session.creationDraft != nil,
              path.last != .setup(.success) else { return }
        push(.success)
    }

    private func startCommit(
        from sourcePath: [WalletSwitcherNavigationRoute]
    ) {
        guard commitTask == nil, !session.isCommitting else { return }
        commitFailure = nil
        commitTask = Task { @MainActor in
            defer { commitTask = nil }

            do {
                try await session.commit()
                try Task.checkCancellation()
                guard path == sourcePath else { return }
                activateCommittedWallet()
            } catch is CancellationError {
                return
            } catch {
                UniHaptic.play(.error)
                commitFailure = WalletPersistenceFailure(error: error)
            }
        }
    }

    private func cancelFailedCommit() {
        guard commitTask == nil,
              !session.isCommitting,
              let last = path.last,
              last == .setup(.success),
              session.identity == nil else { return }
        path.removeLast()
    }

    private func chooseDifferentUnsafeCredential() {
        selectedTrustWalletBackup = nil
        unsafeCredentialWarning = nil
        if let index = path.lastIndex(of: .setup(.importOptions)) {
            path = Array(path.prefix(through: index))
        } else {
            path = [.setup(.importOptions)]
        }
    }

    private func persistenceFailureMessage(
        _ failure: WalletPersistenceFailure
    ) -> String {
        [
            WalletLocalization.string(failure.messageKey),
            EnglishNumbers.localized(
                "wallet.persistence.support.hint",
                WalletSupport.emailAddress
            ),
            EnglishNumbers.localized(
                "wallet.persistence.error.reference",
                failure.diagnosticCode
            )
        ]
        .joined(separator: "\n\n")
    }

    private func finish() {
        guard completionTask == nil, !session.isFinishing else { return }
        completionTask = Task { @MainActor in
            defer { completionTask = nil }
            guard await session.finish(onWalletAdded: onWalletAdded),
                  !Task.isCancelled else { return }
            onDismissRequested()
        }
    }

    private func activateCommittedWallet() {
        guard completionTask == nil, !session.isReady else { return }
        completionTask = Task { @MainActor in
            defer { completionTask = nil }
            _ = await session.finish(onWalletAdded: onWalletAdded)
        }
    }
}

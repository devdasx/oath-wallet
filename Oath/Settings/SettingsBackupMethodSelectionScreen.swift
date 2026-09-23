import SwiftUI
import UIKit

private enum WalletBackupAction {
    case manual, iCloud, removeICloud
}

struct SettingsBackupMethodSelectionScreen: View {
    private let database: WalletDatabase?
    private let walletID: String?
    let material: SettingsBackupMaterialChoice
    let cloudBackupService: WalletAutomaticCloudBackupService
    let isInline: Bool
    private let allowsManualBackup: Bool
    let onBusyChange: (Bool) -> Void

    private let inlineHeader: AnyView?

    init(
        database: WalletDatabase,
        walletID: String,
        material: SettingsBackupMaterialChoice,
        cloudBackupService: WalletAutomaticCloudBackupService = .shared,
        isInline: Bool = false,
        onBusyChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.database = database
        self.walletID = walletID
        self.material = material
        self.cloudBackupService = cloudBackupService
        self.isInline = isInline
        allowsManualBackup = true
        self.onBusyChange = onBusyChange
        inlineHeader = nil
    }

    /// The completion screens keep the same options in the app's native list and
    /// hand their confirmation hero over as that list's header.
    init<Header: View>(
        backupContext: WalletSuccessBackupContext?,
        allowsManualBackup: Bool = true,
        cloudBackupService: WalletAutomaticCloudBackupService = .shared,
        onBusyChange: @escaping (Bool) -> Void = { _ in },
        @ViewBuilder inlineHeader: () -> Header
    ) {
        self.allowsManualBackup = allowsManualBackup
        database = backupContext?.database
        walletID = backupContext?.walletID
        material = .recoveryPhrase
        self.cloudBackupService = cloudBackupService
        isInline = true
        self.onBusyChange = onBusyChange
        self.inlineHeader = AnyView(inlineHeader())
    }

    @Environment(\.openURL) private var openURL
    @State private var wallet: ManagedWallet?
    @State private var isLoading = true
    @State private var loadErrorKey: String?
    @State private var pendingMethod: WalletBackupAction?
    @State private var pendingWritePolicy: WalletCloudBackupWritePolicy = .createOnly
    @State private var showsReplacementConfirmation = false
    @State private var authenticationContext:
        WalletAuthenticationPasscodeContext?
    @State private var isAuthenticationPresented = false
    @State private var pendingAuthenticationGrant: WalletAuthenticationGrant?
    @State private var isPerformingAction = false
    @State private var actionTask: Task<Void, Never>?
    @State private var materialPresentation:
        WalletSensitiveMaterialPresentation?
    @State private var passkeyPresentationWindow: UIWindow?
    @State private var didCompleteICloudBackup = false
    @State private var operationFailure:
        WalletOperationFailurePresentation?

    var body: some View {
        Group {
            if isInline {
                inlineList
            } else {
                settingsList
                    .navigationTitle("settings.wallets.backup.section")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .navigationDestination(
            isPresented: sensitiveMaterialDestinationBinding
        ) {
            if let database, let wallet,
               let presentation = materialPresentation {
                WalletSensitiveAccessView(
                    database: database,
                    wallet: wallet,
                    action: presentation.action,
                    material: presentation.material,
                    onBackupCompleted: loadWallet
                )
                .toolbar(.visible, for: .navigationBar)
                .navigationBarBackButtonHidden(false)
            }
        }
        .fullScreenCover(
            isPresented: $isAuthenticationPresented,
            onDismiss: authenticationDidDismiss
        ) {
            if let database, let context = authenticationContext {
                WalletAuthenticationFullScreenContainer(
                    title: "security.authentication.navigation_title"
                ) {
                    WalletSecurityAuthenticationView(
                        database: database,
                        settings: context.settings,
                        purpose: .walletSensitiveData,
                        beginsWithPasscode: true,
                        initialErrorKey: context.initialErrorKey,
                        onAuthenticationGranted:
                            completePasscodeAuthentication
                    )
                }
            }
        }
        .background {
            WalletPasskeyPresentationAnchorReader { window in
                if passkeyPresentationWindow !== window {
                    passkeyPresentationWindow = window
                }
            }
            .frame(width: 0, height: 0)
        }
        .task(id: walletID) {
            await loadWalletAsync()
        }
        .onChange(of: isBusy, initial: true) { _, busy in
            onBusyChange(busy)
        }
        .onDisappear {
            actionTask?.cancel()
            actionTask = nil
        }
        .confirmationDialog(
            "settings.wallets.backup.replace.title",
            isPresented: $showsReplacementConfirmation,
            titleVisibility: .visible
        ) {
            Button("settings.wallets.backup.replace.confirm", role: .destructive, action: UniHaptic.action {
                if let wallet { request(.iCloud, wallet: wallet, writePolicy: .replaceExisting) }
            })
            Button("settings.wallets.backup.replace.keep", role: .cancel, action: UniHaptic.action {})
        } message: {
            Text("settings.wallets.backup.replace.phrase.message")
        }
        .alert(
            "settings.wallets.operation.error.title",
            isPresented: operationFailureBinding
        ) {
            if let supportURL = operationFailure?.supportURL {
                Button("wallet.persistence.contact_support", action: UniHaptic.action(nil) {
                    openURL(supportURL)
                })
            }
            Button("common.done", role: .cancel, action: UniHaptic.action {
                operationFailure = nil
            })
        } message: {
            if let operationFailure {
                Text(verbatim: operationFailure.message)
            }
        }
    }

    private var settingsList: some View {
        List {
            Group {
                Section {
                    if isLoading {
                        Text("wallet.launch.loading.accessibility")
                            .foregroundStyle(.secondary)
                    } else if let loadErrorKey {
                        WalletManagementErrorRow(
                            messageKey: loadErrorKey,
                            onRetry: loadWallet
                        )
                    } else if let wallet {
                        ForEach(
                            SettingsBackupAndKeysPolicy.methodChoices(
                                for: wallet.kind,
                                material: material
                            ),
                            id: \.self
                        ) { method in
                            Button(methodTitle(method), action: UniHaptic.action {
                                request(method == .manual ? .manual : .iCloud, wallet: wallet)
                            })
                            .disabled(isPerformingAction)
                        }
                    }
                } header: {
                    Text("settings.wallets.backup.section")
                } footer: {
                    Text("settings.wallets.backup.keychain.footer")
                }

                if didCompleteICloudBackup {
                    Section {
                        Text("settings.wallets.backup.icloud.success")
                            .foregroundStyle(WalletTheme.success)
                    } footer: {
                        Text("settings.wallets.backup.icloud.success.footer")
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
    }

    /// The success screens show these options in the same inset list the settings
    /// screens use, so the rows size themselves and keep the system's metrics.
    private var inlineList: some View {
        List {
            Group {
                Section {
                    inlineRows
                } header: {
                    if let inlineHeader {
                        inlineHeader.textCase(nil)
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .scrollBounceBehavior(.basedOnSize)
        .scrollContentBackground(.hidden)
        .background(WalletTheme.groupedBackground)
    }

    @ViewBuilder
    private var inlineRows: some View {
        if let loadErrorKey {
            WalletManagementErrorRow(messageKey: loadErrorKey, onRetry: loadWallet)
        } else if isLoading || wallet?.kind.hasExportableSecret == true {
            WalletICloudBackupToggle(
                isEnabled: Binding(
                    get: { didCompleteICloudBackup },
                    set: { enabled in
                        guard let wallet, enabled != didCompleteICloudBackup else { return }
                        request(enabled ? .iCloud : .removeICloud, wallet: wallet)
                    }
                ),
                // The completion screen only confirms that a backup exists; the
                // timestamp belongs to the wallet's own backup settings.
                lastSuccessfulBackup: nil,
                isDisabled: isBusy || isLoading,
                // Reconciling with iCloud stays behind the screen: the row shows
                // the saved state straight away instead of a spinner.
                isLoading: false,
                accessibilityIdentifier: "walletSuccessICloudBackup"
            )

            if allowsManualBackup && (wallet?.kind.hasRecoveryPhrase ?? true) {
                Button(action: UniHaptic.action {
                    guard let wallet else { return }
                    request(.manual, wallet: wallet)
                }) {
                    LabeledContent {
                        if let wallet, wallet.backupState != .verified {
                            Text("settings.wallets.backup.status.not_complete")
                                .foregroundStyle(WalletTheme.secondaryLabel)
                        }
                    } label: {
                        Text("settings.wallets.backup.manual")
                            .foregroundStyle(WalletTheme.accent)
                    }
                }
                .disabled(isBusy || isLoading)
                .accessibilityIdentifier("walletSuccessManualBackup")
            }
        }
    }

    private var isBusy: Bool {
        isPerformingAction || authenticationContext != nil || materialPresentation != nil
    }

    private var sensitiveMaterialDestinationBinding: Binding<Bool> {
        Binding(
            get: { materialPresentation != nil },
            set: { isPresented in
                if !isPresented {
                    materialPresentation = nil
                    loadWallet()
                }
            }
        )
    }

    private var operationFailureBinding: Binding<Bool> {
        Binding(
            get: { operationFailure != nil },
            set: { isPresented in
                if !isPresented {
                    operationFailure = nil
                }
            }
        )
    }

    private func methodTitle(
        _ method: SettingsBackupMethodChoice
    ) -> LocalizedStringKey {
        switch method {
        case .manual:
            "settings.wallets.backup.manual"
        case .iCloud:
            "settings.wallets.backup.icloud"
        }
    }

    private func loadWallet() {
        Task { await loadWalletAsync() }
    }

    @MainActor
    private func loadWalletAsync() async {
        // Keep the same native rows mounted before persistence supplies an ID.
        guard let database, let walletID else { return }
        isLoading = true
        loadErrorKey = nil
        do {
            let loadedWallet = try await database.managedWallet(
                walletID: walletID
            )
            try Task.checkCancellation()
            guard isInline || SettingsBackupAndKeysPolicy
                .methodChoices(
                    for: loadedWallet.kind,
                    material: material
                )
                .isEmpty == false else {
                throw WalletManagementError.secretUnavailable
            }
            wallet = loadedWallet
            didCompleteICloudBackup = loadedWallet.iCloudBackupUpdatedAt != nil
            isLoading = false
            if isInline {
                await reconcileICloudBackup(loadedWallet)
            }
        } catch is CancellationError {
        } catch {
            loadErrorKey = "settings.wallets.details.load.error"
            isLoading = false
        }
    }

    /// The completion screen already shows the saved state, so confirming it
    /// against iCloud runs behind the screen and only corrects what it finds.
    @MainActor
    private func reconcileICloudBackup(_ loadedWallet: ManagedWallet) async {
        guard let database else { return }
        let currentWallet = await WalletICloudBackupReconciliation.refresh(
            database: database, wallet: loadedWallet, service: cloudBackupService
        )
        guard !Task.isCancelled, !isBusy, wallet?.id == currentWallet.id else { return }
        wallet = currentWallet
        didCompleteICloudBackup = currentWallet.iCloudBackupUpdatedAt != nil
    }

    @MainActor
    private func request(
        _ method: WalletBackupAction,
        wallet: ManagedWallet,
        writePolicy: WalletCloudBackupWritePolicy = .createOnly
    ) {
        guard let database, !isBusy, !isLoading, wallet.kind.hasExportableSecret else { return }
        UniHaptic.play(.selection)
        pendingMethod = method
        pendingWritePolicy = writePolicy
        isPerformingAction = true
        actionTask = Task { @MainActor in
            defer {
                isPerformingAction = false
                actionTask = nil
            }
            do {
                if method == .iCloud, writePolicy == .createOnly {
                    let backedUpWallet = try await WalletICloudPasskeyBackupCreation.existingBackup(
                        database: database, wallet: wallet, service: cloudBackupService
                    )
                    try Task.checkCancellation()
                    didCompleteICloudBackup = backedUpWallet != nil
                    if let backedUpWallet {
                        self.wallet = backedUpWallet
                        pendingMethod = nil
                        // Enabling an inline switch only needs a verified backup;
                        // it must not replace a backup that already exists.
                        if !isInline { showsReplacementConfirmation = true }
                        return
                    }
                    self.wallet = try await database.managedWallet(walletID: wallet.id)
                }
                if method == .iCloud {
                    // The passkey verifies the user before issuing wallet-scoped
                    // permission to read the secret. App authentication here
                    // would ask for Face ID or a passcode a second time.
                    pendingMethod = nil
                    try await WalletAuthenticationPresentationReadiness().wait()
                    try await createICloudBackup(wallet: wallet, writePolicy: writePolicy)
                    return
                }
                let preparation = try await WalletSensitiveActionAuthorizer
                    .prepare(database: database)
                guard !Task.isCancelled else { return }
                switch preparation {
                case let .authorized(grant):
                    pendingMethod = nil
                    try await execute(method, wallet: wallet, grant: grant, writePolicy: writePolicy)
                case let .requiresPasscode(context):
                    authenticationContext = context
                    isAuthenticationPresented = true
                case .cancelled:
                    pendingMethod = nil
                }
            } catch is CancellationError {
            } catch {
                pendingMethod = nil
                presentFailure(error, method: method)
            }
        }
    }

    @MainActor
    private func completePasscodeAuthentication(
        _ grant: WalletAuthenticationGrant
    ) {
        pendingAuthenticationGrant = grant
        isAuthenticationPresented = false
    }

    @MainActor
    private func authenticationDidDismiss() {
        let grant = pendingAuthenticationGrant
        let method = pendingMethod
        pendingAuthenticationGrant = nil
        authenticationContext = nil
        pendingMethod = nil
        guard let grant, let method, let wallet else { return }
        beginExecution(method, wallet: wallet, grant: grant, writePolicy: pendingWritePolicy)
    }

    @MainActor
    private func beginExecution(
        _ method: WalletBackupAction,
        wallet: ManagedWallet,
        grant: WalletAuthenticationGrant,
        writePolicy: WalletCloudBackupWritePolicy
    ) {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        actionTask = Task { @MainActor in
            defer {
                isPerformingAction = false
                actionTask = nil
            }
            do {
                try await execute(method, wallet: wallet, grant: grant, writePolicy: writePolicy)
            } catch is CancellationError {
            } catch {
                presentFailure(error, method: method)
            }
        }
    }

    @MainActor
    private func execute(
        _ method: WalletBackupAction,
        wallet: ManagedWallet,
        grant: WalletAuthenticationGrant,
        writePolicy: WalletCloudBackupWritePolicy
    ) async throws {
        guard let database else { throw WalletManagementError.walletNotFound }
        try await WalletAuthenticationPresentationReadiness().wait()
        switch method {
        case .iCloud:
            try await createICloudBackup(wallet: wallet, writePolicy: writePolicy)
        case .removeICloud:
            _ = try await database.authorizeSecretExport(
                walletID: wallet.id,
                authenticationGrant: grant
            )
            try await cloudBackupService.removeBackup(
                walletID: wallet.iCloudBackupWalletID ?? wallet.id
            )
            try await database.clearICloudBackupRemoteVerification(walletID: wallet.id)
            self.wallet = try await database.managedWallet(walletID: wallet.id)
            didCompleteICloudBackup = false
            UniHaptic.play(.successQuiet)
        case .manual:
            let authorization = try await database.authorizeSecretExport(
                walletID: wallet.id,
                authenticationGrant: grant
            )
            let sensitiveMaterial = try await database.sensitiveMaterial(
                walletID: wallet.id,
                authorization: authorization
            )
            try Task.checkCancellation()
            if !isInline {
                guard case .recoveryPhrase = sensitiveMaterial else {
                    throw WalletManagementError.secretUnavailable
                }
            }
            materialPresentation = WalletSensitiveMaterialPresentation(
                action: .manualBackup,
                material: sensitiveMaterial
            )
        }
    }

    @MainActor
    private func createICloudBackup(
        wallet: ManagedWallet,
        writePolicy: WalletCloudBackupWritePolicy
    ) async throws {
        guard let database else { throw WalletManagementError.walletNotFound }
        try await WalletICloudPasskeyBackupCreation.create(
            database: database,
            wallet: wallet,
            presentationAnchor: passkeyPresentationWindow,
            writePolicy: writePolicy,
            service: cloudBackupService
        )
        self.wallet = try await database.managedWallet(walletID: wallet.id)
        didCompleteICloudBackup = true
        UniHaptic.play(.successQuiet)
    }

    @MainActor
    private func presentFailure(
        _ error: Error,
        method: WalletBackupAction
    ) {
        if error is CancellationError { return }
        if error is WalletCloudBackupReplacementRequired {
            showsReplacementConfirmation = true
            return
        }
        if error.walletCloudBackupCategory == .passkeyCanceled {
            return
        }

        switch method {
        case .iCloud:
            operationFailure = WalletICloudPasskeyBackupCreation.failure(
                for: error
            )
        case .manual:
            operationFailure = WalletOperationFailurePresentation(
                messageKey: "settings.wallets.secret.error",
                error: error
            )
        case .removeICloud:
            operationFailure = WalletOperationFailurePresentation(
                messageKey: "settings.wallets.backup.icloud.disable.error",
                error: error
            )
        }
        UniHaptic.play(.error)
    }
}

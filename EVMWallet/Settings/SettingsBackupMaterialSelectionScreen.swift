import SwiftUI

struct SettingsBackupMaterialSelectionScreen: View {
    let database: WalletDatabase
    let walletID: String
    let onRecoveryPhraseSelected: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var privateKeyAccess: SettingsBackupPrivateKeyAccess
    @State private var privateKeyTask: Task<Void, Never>?

    @State private var wallet: ManagedWallet
    @State private var isLoading = true
    @State private var loadErrorKey: String?

    init(
        database: WalletDatabase,
        wallet: ManagedWallet,
        onRecoveryPhraseSelected: @escaping () -> Void
    ) {
        self.database = database
        self.walletID = wallet.id
        _wallet = State(initialValue: wallet)
        self.onRecoveryPhraseSelected = onRecoveryPhraseSelected
        _privateKeyAccess = State(initialValue: SettingsBackupPrivateKeyAccess(
            database: database,
            walletID: wallet.id
        ))
    }

    var body: some View {
        List {
            Group {
                Section("settings.wallets.backup.section") {
                    if isLoading {
                        Text("wallet.launch.loading.accessibility")
                            .foregroundStyle(.secondary)
                    } else if let loadErrorKey {
                        WalletManagementErrorRow(
                            messageKey: loadErrorKey,
                            onRetry: loadWallet
                        )
                    } else {
                        ForEach(
                            SettingsBackupAndKeysPolicy.materialChoices(
                                for: wallet.kind
                            ),
                            id: \.self
                        ) { choice in
                            Button(materialTitle(choice, wallet: wallet), action: UniHaptic.action(nil) {
                                switch choice {
                                case .recoveryPhrase:
                                    onRecoveryPhraseSelected()
                                case .privateKeys:
                                    privateKeyTask = Task {
                                        await privateKeyAccess.request()
                                    }
                                }
                            })
                            .disabled(
                                privateKeyAccess.isBusy
                                    || privateKeyAccess.authenticationContext != nil
                            )
                        }
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle(
            EnglishNumbers.localized(
                "settings.wallets.backup.wallet.title_format",
                wallet.name
            )
        )
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $privateKeyAccess.route) { _ in
            SettingsBackupPrivateKeyFlow(
                wallet: wallet,
                items: privateKeyAccess.items
            )
        }
        .fullScreenCover(
            isPresented: $privateKeyAccess.isAuthenticationPresented,
            onDismiss: {
                privateKeyTask = Task {
                    await privateKeyAccess.authenticationDidDismiss()
                }
            }
        ) {
            if let context = privateKeyAccess.authenticationContext {
                WalletAuthenticationFullScreenContainer(
                    title: "security.authentication.navigation_title"
                ) {
                    WalletSecurityAuthenticationView(
                        database: database,
                        settings: context.settings,
                        purpose: .walletSensitiveData,
                        beginsWithPasscode: true,
                        initialErrorKey: context.initialErrorKey,
                        onAuthenticationGranted: privateKeyAccess.completePasscode
                    )
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                SettingsBackupWalletTitle(wallet: wallet)
            }
        }
        .task {
            await loadWalletAsync()
        }
        .onChange(of: privateKeyAccess.route) { _, route in
            if route == nil { privateKeyAccess.clearExport() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                privateKeyAccess.sceneBecameActive()
            case .inactive:
                privateKeyAccess.sceneBecameInactive()
            case .background:
                privateKeyTask?.cancel()
                privateKeyAccess.sceneBecameInactive()
                privateKeyAccess.cancelPendingRequest()
            @unknown default:
                privateKeyAccess.sceneBecameInactive()
            }
        }
        .onDisappear {
            privateKeyTask?.cancel()
            privateKeyTask = nil
            if privateKeyAccess.authenticationContext == nil {
                privateKeyAccess.cancelPendingRequest()
            }
        }
        .alert(
            "settings.wallets.operation.error.title",
            isPresented: Binding(
                get: { privateKeyAccess.failure != nil },
                set: { if !$0 { privateKeyAccess.failure = nil } }
            )
        ) {
            if let supportURL = privateKeyAccess.failure?.supportURL {
                Button("wallet.persistence.contact_support", action: UniHaptic.action(nil) { openURL(supportURL) })
            }
            Button("common.done", role: .cancel, action: UniHaptic.action { privateKeyAccess.failure = nil })
        } message: {
            if let failure = privateKeyAccess.failure {
                Text(verbatim: failure.message)
            }
        }
    }

    private func materialTitle(
        _ choice: SettingsBackupMaterialChoice,
        wallet: ManagedWallet
    ) -> LocalizedStringKey {
        switch choice {
        case .recoveryPhrase:
            "settings.wallets.recovery.navigation"
        case .privateKeys:
            wallet.kind == .importedPrivateKey
                ? "settings.wallets.private_key.view"
                : "settings.wallets.private_keys.export"
        }
    }

    private func loadWallet() {
        Task { await loadWalletAsync() }
    }

    @MainActor
    private func loadWalletAsync() async {
        isLoading = true
        loadErrorKey = nil
        do {
            let loadedWallet = try await database.managedWallet(
                walletID: walletID
            )
            try Task.checkCancellation()
            guard SettingsBackupAndKeysPolicy.includes(loadedWallet.kind)
            else {
                throw WalletManagementError.secretUnavailable
            }
            wallet = loadedWallet
            isLoading = false
        } catch is CancellationError {
        } catch {
            loadErrorKey = "settings.wallets.details.load.error"
            isLoading = false
        }
    }
}

private struct SettingsBackupWalletTitle: View {
    let wallet: ManagedWallet

    private var titleParts: [String] {
        WalletLocalization.string("settings.wallets.backup.wallet.title_format")
            .components(separatedBy: "%@")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    var body: some View {
        HStack(spacing: 6) {
            if let prefix = titleParts.first, !prefix.isEmpty {
                Text(verbatim: prefix)
                    .layoutPriority(1)
            }

            HStack(spacing: 6) {
                WalletIdentityIcon(
                    color: wallet.appearanceColor,
                    placement: .toolbar
                )
                .fixedSize()

                Text(verbatim: wallet.name)
                    .truncationMode(.tail)
            }

            if let suffix = titleParts.last, !suffix.isEmpty {
                Text(verbatim: suffix)
                    .layoutPriority(1)
            }
        }
        .font(WalletTypography.sheetTitle)
        .foregroundStyle(WalletTheme.primaryLabel)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: EnglishNumbers.localized(
            "settings.wallets.backup.wallet.title_format",
            wallet.name
        )))
        .accessibilityAddTraits(.isHeader)
    }
}

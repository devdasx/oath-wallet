import SwiftUI

struct RemoveWalletIntroductionScreen: View {
    let database: WalletDatabase
    let walletID: String
    let onRemoved: (WalletRemovalResult) -> Void
    let onNotNow: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var settings: WalletSecuritySettings?
    @State private var wallet: ManagedWallet?
    @State private var removalPlan: WalletRemovalPlan?
    @State private var loadFailed = false
    @State private var removalAuthenticationRoute:
        RemoveWalletAuthenticationRoute?
    @State private var beginsRemovalAfterAuthentication = false
    @State private var removalProgressPresented = false
    @State private var completedRemoval: WalletRemovalResult?
    @State private var learnMorePresented = false
    @State private var operationFailure:
        WalletOperationFailurePresentation?
    @State private var passkeyPresentationAnchor:
        WalletPasskeyPresentationAnchor?
    @State private var removalErrorPresented = false
    @State private var isPreparingAuthorization = false
    @State private var isAccessingWalletSecret = false
    @State private var isUpdatingICloudBackup = false
    @State private var isICloudBackupEnabled = false
    @State private var backupTask: Task<Void, Never>?

    var body: some View {
        List {
            Group {
                removalOverview

                if let removalPlan {
                    Section {
                        if removalPlan.hasICloudBackup {
                            Text(
                                "settings.wallets.remove.icloud_preserved.message"
                            )
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        } else if let wallet,
                                  wallet.kind.hasExportableSecret {
                            WalletICloudBackupToggle(
                                isEnabled: iCloudBackupBinding(wallet: wallet),
                                lastSuccessfulBackup: nil,
                                isDisabled: isBackupControlDisabled
                            )
                        } else {
                            Text(
                                "settings.wallets.remove.icloud_preserved.none"
                            )
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } header: {
                        Text(
                            "settings.wallets.remove.icloud_preserved.section"
                        )
                    } footer: {
                        if shouldOfferICloudBackup {
                            Text(verbatim: WalletLocalization.string(
                                "settings.wallets.remove.icloud_preserved.footer"
                            ))
                        }
                    }
                }

                if loadFailed {
                    Section {
                        Text("settings.wallets.remove.load.error.message")
                            .foregroundStyle(WalletTheme.danger)

                        Button("settings.wallets.remove.error.retry", action: UniHaptic.action {
                            loadFailed = false
                            Task {
                                await load()
                            }
                        })
                    } header: {
                        Text("settings.wallets.remove.load.error.title")
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(WalletTheme.groupedBackground)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar(.visible, for: .navigationBar)
        .walletSafeAreaBar(edge: .bottom, spacing: 0) {
            actionBar
        }
        .fullScreenCover(
            item: $removalAuthenticationRoute,
            onDismiss: removalAuthenticationFullScreenDidDismiss
        ) { route in
            WalletAuthenticationFullScreenContainer(
                title: "security.authentication.navigation_title"
            ) {
                RemoveWalletAuthenticationScreen(
                    database: database,
                    context: route.context,
                    onAuthenticationGranted:
                        completeRemovalAuthentication
                )
            }
        }
        .sheet(
            isPresented: $removalProgressPresented,
            onDismiss: removalProgressDidDismiss
        ) {
            if let removalPlan {
                RemoveWalletProgressSheet(
                    database: database,
                    removalPlan: removalPlan,
                    onRemoved: { result in
                        completedRemoval = result
                        removalProgressPresented = false
                    }
                ) {
                    removalProgressPresented = false
                }
            }
        }
        .sheet(isPresented: $learnMorePresented) {
            RemoveWalletLearnMoreSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert(
            "settings.wallets.remove.error.title",
            isPresented: $removalErrorPresented
        ) {
            Button("common.cancel", role: .cancel, action: UniHaptic.action {})
            Button("settings.wallets.remove.error.retry", action: UniHaptic.action {
                Task {
                    await prepareRemovalAuthorization()
                }
            })
        } message: {
            Text("settings.wallets.remove.error.message")
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
        .background {
            WalletPasskeyPresentationAnchorReader { anchor in
                if passkeyPresentationAnchor !== anchor {
                    passkeyPresentationAnchor = anchor
                }
            }
            .frame(width: 0, height: 0)
        }
        .onDisappear {
            backupTask?.cancel()
            backupTask = nil
        }
        .task {
            guard settings == nil,
                  wallet == nil,
                  removalPlan == nil,
                  !loadFailed else {
                return
            }
            await load()
        }
    }

    private func removalProgressDidDismiss() {
        guard let result = completedRemoval else { return }
        completedRemoval = nil
        onRemoved(result)
    }

    private var removalOverview: some View {
        Section {
            if let removalPlan {
                WalletDataRemovalRow(
                    title: "settings.wallets.remove.contents.accounts.title",
                    detail: "settings.wallets.remove.contents.accounts",
                    icon: .wallets
                )

                if removalPlan.walletKind.hasRecoveryPhrase {
                    WalletDataRemovalRow(
                        title: "settings.wallets.remove.contents.recovery_phrase.title",
                        detail: "settings.wallets.remove.contents.recovery_phrase",
                        icon: .recoveryPhrase
                    )
                } else if removalPlan.walletKind == .importedPrivateKey {
                    WalletDataRemovalRow(
                        title: "settings.wallets.remove.contents.private_key.title",
                        detail: "settings.wallets.remove.contents.private_key",
                        icon: .privateKey
                    )
                }

                WalletDataRemovalRow(
                    title: "settings.wallets.remove.contents.activity.title",
                    detail: "settings.wallets.remove.contents.activity",
                    icon: .activity
                )
            } else if !loadFailed {
                Text("settings.wallets.remove.loading")
                    .foregroundStyle(.secondary)
            }
        } header: {
            VStack(alignment: .leading, spacing: 12) {
                Text("settings.wallets.remove.navigation.title")
                    .font(WalletTypography.title(.largeTitle))
                    .foregroundStyle(WalletTheme.primaryLabel)
                    .textCase(nil)

                Text("settings.wallets.remove.review.message")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textCase(nil)
            }
            .padding(.bottom, 16)
        }
        .headerProminence(.increased)
    }

    private var actionBar: some View {
        VStack(spacing: 0) {
            DestructiveActionWarning(
                message: WalletLocalization.string(
                    "settings.reset.review.irreversible"
                ),
                learnMoreTitle: WalletLocalization.string(
                    "common.learn_more.inline"
                ),
                learnMoreAccessibilityIdentifier:
                    "removeWalletLearnMore"
            ) {
                learnMorePresented = true
            }

            VStack(spacing: 10) {
                PrimaryWalletButton(
                    title: "common.continue",
                    hapticPolicy: .custom(.warning)
                ) {
                    Task {
                        await prepareRemovalAuthorization()
                    }
                }
                .disabled(
                    settings == nil
                        || removalPlan == nil
                        || isPreparingAuthorization
                        || removalProgressPresented
                        || isAccessingWalletSecret
                        || isUpdatingICloudBackup
                )

                SecondaryWalletButton(
                    title: "common.not_now"
                ) {
                    onNotNow()
                }
                .disabled(
                    isPreparingAuthorization
                        || removalProgressPresented
                        || isAccessingWalletSecret
                        || isUpdatingICloudBackup
                )
            }
        }
        .walletActionScreenMargins()
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var shouldOfferICloudBackup: Bool {
        guard let removalPlan, let wallet else { return false }
        return !removalPlan.hasICloudBackup
            && wallet.kind.hasExportableSecret
    }

    private var isBackupControlDisabled: Bool {
        isAccessingWalletSecret
            || isUpdatingICloudBackup
            || isPreparingAuthorization
            || removalProgressPresented
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

    @MainActor
    private func load() async {
        do {
            async let settings = database.walletSecuritySettings()
            async let wallet = database.managedWallet(
                walletID: walletID
            )
            let loaded = try await (settings, wallet)
            let reconciledWallet =
                await WalletICloudBackupReconciliation.refresh(
                    database: database,
                    wallet: loaded.1
                )
            let freshRemovalPlan = try await database.prepareWalletRemoval(
                walletID: walletID
            )
            self.settings = loaded.0
            self.wallet = reconciledWallet
            removalPlan = freshRemovalPlan
            isICloudBackupEnabled = freshRemovalPlan.hasICloudBackup
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    private func iCloudBackupBinding(
        wallet: ManagedWallet
    ) -> Binding<Bool> {
        Binding(
            get: { isICloudBackupEnabled },
            set: { isEnabled in
                guard isEnabled,
                      !isICloudBackupEnabled,
                      !isBackupControlDisabled else {
                    return
                }
                requestICloudBackupEnable(wallet: wallet)
            }
        )
    }

    private func requestICloudBackupEnable(
        wallet: ManagedWallet
    ) {
        guard !isAccessingWalletSecret,
              !isUpdatingICloudBackup else {
            return
        }

        isAccessingWalletSecret = true
        backupTask = Task { @MainActor in
            defer {
                isAccessingWalletSecret = false
                backupTask = nil
            }

            do {
                try await createICloudBackup(wallet: wallet)
            } catch is CancellationError {
            } catch {
                handleICloudBackupFailure(error)
            }
        }
    }

    @MainActor
    private func createICloudBackup(
        wallet: ManagedWallet
    ) async throws {
        isUpdatingICloudBackup = true
        defer {
            isUpdatingICloudBackup = false
        }

        try await WalletICloudPasskeyBackupCreation.create(
            database: database,
            wallet: wallet,
            presentationAnchor: passkeyPresentationAnchor
        )
        isICloudBackupEnabled = true

        do {
            try await refreshRemovalStateAfterBackup()
        } catch {
            removalPlan = nil
            loadFailed = true
            operationFailure = WalletOperationFailurePresentation(
                messageKey: "settings.wallets.remove.load.error.message",
                error: error
            )
            UniHaptic.play(.error)
            return
        }

        UniHaptic.play(.successQuiet)
    }

    @MainActor
    private func refreshRemovalStateAfterBackup() async throws {
        async let wallet = database.managedWallet(walletID: walletID)
        async let removalPlan = database.prepareWalletRemoval(
            walletID: walletID
        )
        let refreshed = try await (wallet, removalPlan)
        self.wallet = refreshed.0
        self.removalPlan = refreshed.1
        isICloudBackupEnabled = refreshed.1.hasICloudBackup
        loadFailed = false
    }

    @MainActor
    private func handleICloudBackupFailure(_ error: Error) {
        isICloudBackupEnabled = removalPlan?.hasICloudBackup ?? false

        if error.walletCloudBackupCategory == .passkeyCanceled {
            return
        }

        operationFailure =
            WalletICloudPasskeyBackupCreation.failure(for: error)
        UniHaptic.play(.error)
    }

    @MainActor
    private func prepareRemovalAuthorization() async {
        guard removalPlan != nil,
              !isPreparingAuthorization,
              !removalProgressPresented,
              !isAccessingWalletSecret,
              !isUpdatingICloudBackup else {
            return
        }

        isPreparingAuthorization = true
        defer {
            isPreparingAuthorization = false
        }

        do {
            let currentSettings = try await database.walletSecuritySettings()
            switch WalletAuthenticationAction.preparePasscodeOnly(
                settings: currentSettings
            ) {
            case .authorized:
                presentRemovalProgress()
            case let .requiresPasscode(context):
                removalAuthenticationRoute =
                    RemoveWalletAuthenticationRoute(context: context)
            case .cancelled:
                break
            }
        } catch {
            removalErrorPresented = true
        }
    }

    private func completeRemovalAuthentication() {
        beginsRemovalAfterAuthentication = true
        removalAuthenticationRoute = nil
    }

    private func removalAuthenticationFullScreenDidDismiss() {
        guard beginsRemovalAfterAuthentication else { return }
        beginsRemovalAfterAuthentication = false
        presentRemovalProgress()
    }

    private func presentRemovalProgress() {
        guard removalPlan != nil, !removalProgressPresented else {
            return
        }
        removalProgressPresented = true
    }
}

import SwiftUI

private enum WalletManagementFilter: String, CaseIterable, Identifiable {
    case all
    case current
    case created
    case imported
    case needsBackup
    case backedUp
    case iCloudBackedUp

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all:
            "settings.wallets.filter.all"
        case .current:
            "settings.wallets.filter.current"
        case .created:
            "settings.wallets.filter.created"
        case .imported:
            "settings.wallets.filter.imported"
        case .needsBackup:
            "settings.wallets.filter.needs_backup"
        case .backedUp:
            "settings.wallets.filter.backed_up"
        case .iCloudBackedUp:
            "settings.wallets.filter.icloud"
        }
    }

    func includes(_ wallet: ManagedWallet) -> Bool {
        switch self {
        case .all:
            true
        case .current:
            wallet.isSelected
        case .created:
            wallet.kind == .created
        case .imported:
            wallet.kind == .importedRecoveryPhrase
                || wallet.kind == .importedPrivateKey
        case .needsBackup:
            wallet.needsBackup
        case .backedUp:
            wallet.backupState == .verified
                || wallet.iCloudBackupUpdatedAt != nil
        case .iCloudBackedUp:
            wallet.iCloudBackupUpdatedAt != nil
        }
    }
}

private enum WalletManagementAddWalletFlow: Identifiable {
    case create(WalletCreationDraft)
    case onboarding(OnboardingStartAction)

    var id: String {
        switch self {
        case .create:
            "create"
        case let .onboarding(action):
            "onboarding-\(action.rawValue)"
        }
    }
}

struct WalletManagementSettingsView: View {
    let database: WalletDatabase
    let initialWalletSettingsID: String?
    let onWalletSelected: (String) -> Void
    let onWalletRenamed: (String, String) -> Void
    let onWalletAppearanceChanged:
        (String, WalletAppearanceColor) -> Void
    let onWalletSetupCompleted: (String) -> Void
    let onRemoveWalletRequested: (String) -> Void

    @Environment(WalletSettingsStore.self) private var applicationSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var wallets: [ManagedWallet] = []
    @State private var isLoading = true
    @State private var loadErrorKey: String?
    @State private var addWalletFlow: WalletManagementAddWalletFlow?
    @State private var walletCreationTask: Task<Void, Never>?
    @State private var creationErrorPresented = false
    @State private var filter: WalletManagementFilter = .all
    @State private var walletForSettings: ManagedWallet?
    @State private var didRestoreInitialWalletSettings = false
    @State private var walletSetupCompletionTask: Task<Void, Never>?
    @State private var walletSetupCompletion =
        WalletSetupSheetCompletion()

    private var isBalanceHidden: Bool {
        applicationSettings.balancePrivacyEnabled
    }

    var body: some View {
        let visibleWallets = filteredWallets

        List {
            Group {
                Section("settings.wallets.section.wallets") {
                    if isLoading {
                        Text("wallet.launch.loading.accessibility")
                            .foregroundStyle(.secondary)
                    } else if let loadErrorKey {
                        WalletManagementErrorRow(
                            messageKey: loadErrorKey,
                            onRetry: loadWallets
                        )
                    } else if wallets.isEmpty {
                        WalletEmptyStateView(
                            "settings.wallets.empty.title",
                            message: "settings.wallets.empty.message"
                        )
                    } else if visibleWallets.isEmpty {
                        WalletEmptyStateView(
                            "settings.wallets.filter.empty.title",
                            message: "settings.wallets.filter.empty.message"
                        )
                    } else {
                        ForEach(visibleWallets) { wallet in
                            ZStack(alignment: .trailing) {
                                WalletSettingsManagementRow(
                                    wallet: wallet,
                                    walletCount: wallets.count,
                                    isBalanceHidden: isBalanceHidden,
                                    onSelect: {
                                        walletForSettings = wallet
                                    }
                                )

                                WalletRowInformationButton {
                                    walletForSettings = wallet
                                }
                            }
                        }
                    }
                }

                WalletManagementAddActionsSection(
                    onCreate: beginWalletCreation,
                    onImport: {
                        addWalletFlow = .onboarding(.importWallet)
                    },
                    onRestoreICloud: {
                        addWalletFlow = .onboarding(.restoreICloud)
                    }
                )
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("settings.wallets.title")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $walletForSettings) { wallet in
            walletSettingsDestination(wallet)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker(
                        "settings.wallets.filter.title",
                        selection: $filter
                    ) {
                        ForEach(WalletManagementFilter.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .fontWeight(WalletSFSymbol.weight)
                }
                .accessibilityLabel(
                    Text("settings.wallets.filter.title")
                )
                .accessibilityValue(Text(filter.title))
            }
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.24),
            value: filter
        )
        .task {
            await loadWalletsAsync()
        }
        .sheet(
            item: $addWalletFlow,
            onDismiss: finishPendingWalletSetup
        ) { flow in
            Group {
                switch flow {
                case let .create(draft):
                    SettingsWalletCreationFlow(
                        database: database,
                        draft: draft,
                        onPrepareWalletForOpen: prepareAddedWallet,
                        onCompleted: queueWalletSetupCompletion
                    )
                case let .onboarding(startAction):
                    OnboardingView(
                        database: database,
                        startAction: startAction,
                        usesExistingProfileSecurity: true,
                        onPrepareWalletForOpen: prepareAddedWallet,
                        onOpenWallet: { address in
                            queueWalletSetupCompletion(address: address)
                        }
                    )
                }
            }
            .walletSheetPresentation(nativeGlass: false)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .alert(
            "wallet.creation.error.title",
            isPresented: $creationErrorPresented
        ) {
            Button("common.cancel", role: .cancel, action: UniHaptic.action {})
            Button("common.try_again", action: UniHaptic.action(beginWalletCreation))
        } message: {
            Text("wallet.creation.generate.error")
        }
        .onDisappear {
            walletCreationTask?.cancel()
            walletCreationTask = nil
            walletSetupCompletionTask?.cancel()
            walletSetupCompletionTask = nil
            walletSetupCompletion.cancel()
        }
    }

    @MainActor
    private func beginWalletCreation() {
        guard walletCreationTask == nil, addWalletFlow == nil else { return }
        creationErrorPresented = false
        walletCreationTask = Task { @MainActor in
            defer { walletCreationTask = nil }
            do {
                let draft = try await Task.detached(
                    priority: .userInitiated
                ) {
                    try WalletCoreService.generateEVMWallet()
                }.value
                try Task.checkCancellation()
                addWalletFlow = .create(draft)
            } catch is CancellationError {
                return
            } catch {
                UniHaptic.play(.error)
                creationErrorPresented = true
            }
        }
    }

    @ViewBuilder
    private func walletSettingsDestination(
        _ wallet: ManagedWallet
    ) -> some View {
        WalletDetailSettingsView(
            database: database,
            walletID: wallet.id,
            onWalletSelected: { address in
                onWalletSelected(address)
                loadWallets()
            },
            onWalletRenamed: { address, name in
                onWalletRenamed(address, name)
                loadWallets()
            },
            onWalletAppearanceChanged: onWalletAppearanceChanged,
            onWalletChanged: loadWallets,
            onRemoveWalletRequested: onRemoveWalletRequested
        )
    }

    private func loadWallets() {
        Task {
            await loadWalletsAsync()
        }
    }

    private var filteredWallets: [ManagedWallet] {
        wallets.filter(filter.includes)
    }

    @MainActor
    private func prepareAddedWallet(_ address: String) async -> Bool {
        onWalletSelected(address)
        return true
    }

    @MainActor
    private func queueWalletSetupCompletion(address: String) {
        guard walletSetupCompletion.queue(walletAddress: address) else {
            return
        }
        addWalletFlow = nil
    }

    @MainActor
    private func finishPendingWalletSetup() {
        let address = walletSetupCompletion.consumeAfterSheetDismissal()

        walletSetupCompletionTask?.cancel()
        walletSetupCompletionTask = Task { @MainActor in
            defer {
                walletSetupCompletionTask = nil
            }
            await loadWalletsAsync()
            guard !Task.isCancelled else {
                return
            }
            if let address { onWalletSetupCompleted(address) }
        }
    }

    @MainActor
    private func loadWalletsAsync() async {
        isLoading = wallets.isEmpty
        loadErrorKey = nil
        do {
            wallets = try await database.managedWallets()
            restoreInitialWalletSettingsIfNeeded()
            isLoading = false
        } catch {
            loadErrorKey = "settings.wallets.load.error"
            isLoading = false
        }
    }

    @MainActor
    private func restoreInitialWalletSettingsIfNeeded() {
        guard !didRestoreInitialWalletSettings else { return }
        didRestoreInitialWalletSettings = true
        guard let initialWalletSettingsID else { return }
        walletForSettings = wallets.first {
            $0.id == initialWalletSettingsID
        }
    }
}

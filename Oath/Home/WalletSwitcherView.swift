import SwiftUI

enum WalletSwitcherRowHitTarget: Equatable, Sendable {
    case content
    case information
}

enum WalletSwitcherRowAction: Equatable, Sendable {
    case activateWallet
    case openWalletSettings
}

enum WalletSwitcherRowInteractionPolicy {
    static func action(
        for target: WalletSwitcherRowHitTarget
    ) -> WalletSwitcherRowAction {
        switch target {
        case .content:
            .activateWallet
        case .information:
            .openWalletSettings
        }
    }
}

struct WalletSwitcherView: View {
    let database: WalletDatabase
    let isAppSwitcherPrivacyActive: Bool
    let refreshGeneration: UUID
    let onWalletSelected: (ManagedWallet, String) async -> Bool
    let onWalletSettingsRequested: (ManagedWallet) -> Void
    let onAddWalletRequested: (HomeWalletAddAction) -> Void
    let onDismissRequested: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(WalletSettingsStore.self) private var applicationSettings
    @State private var wallets: [ManagedWallet] = []
    @State private var isLoading = true
    @State private var loadErrorKey: String?
    @State private var selectionErrorKey: String?
    @State private var selectingWalletID: String?
    @State private var walletSelectionTask: Task<Void, Never>?

    var body: some View {
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
                    } else {
                        ForEach(wallets) { wallet in
                            walletSwitcherRow(wallet)
                                .moveDisabled(selectingWalletID != nil)
                        }
                        .onMove(perform: moveWallets)
                    }
                }

                if let selectionErrorKey {
                    Section {
                        Text(LocalizedStringKey(selectionErrorKey))
                            .font(.subheadline)
                            .foregroundStyle(WalletTheme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                WalletManagementAddActionsSection(
                    onCreate: {
                        onAddWalletRequested(.create)
                    },
                    onImport: {
                        onAddWalletRequested(.importWallet)
                    },
                    onRestoreICloud: {
                        onAddWalletRequested(.restoreICloud)
                    }
                )
                .disabled(selectingWalletID != nil)
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .walletPrivacySensitive()
        .navigationTitle("settings.wallets.title")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(selectingWalletID != nil)
        .task {
            await loadWalletsAsync()
        }
        .onChange(of: refreshGeneration) { _, _ in
            loadWallets()
        }
        .onDisappear {
            walletSelectionTask?.cancel()
            walletSelectionTask = nil
        }
    }

    private func loadWallets() {
        Task {
            await loadWalletsAsync()
        }
    }

    @MainActor
    private func loadWalletsAsync() async {
        isLoading = wallets.isEmpty
        loadErrorKey = nil
        selectionErrorKey = nil
        do {
            wallets = try await database.managedWallets()
            isLoading = false
        } catch {
            loadErrorKey = "settings.wallets.load.error"
            isLoading = false
        }
    }

    private func select(_ wallet: ManagedWallet) {
        guard selectingWalletID == nil else { return }
        guard !wallet.isSelected else {
            onDismissRequested()
            return
        }

        selectingWalletID = wallet.id
        selectionErrorKey = nil
        walletSelectionTask = Task { @MainActor in
            defer { walletSelectionTask = nil }
            do {
                let identity = try await database.selectWallet(
                    walletID: wallet.id
                )
                PushNotificationCoordinator.shared.walletDataDidChange()
                let isReady = await onWalletSelected(
                    wallet,
                    identity.address
                )
                guard isReady else {
                    selectingWalletID = nil
                    selectionErrorKey =
                        "settings.wallets.select.error"
                    return
                }
                onDismissRequested()
            } catch {
                withAnimation(
                    reduceMotion ? nil : .smooth(duration: 0.24)
                ) {
                    selectingWalletID = nil
                    selectionErrorKey =
                        "settings.wallets.select.error"
                }
            }
        }
    }

    private func handleRowInteraction(
        _ target: WalletSwitcherRowHitTarget,
        wallet: ManagedWallet
    ) {
        switch WalletSwitcherRowInteractionPolicy.action(for: target) {
        case .activateWallet:
            select(wallet)
        case .openWalletSettings:
            onWalletSettingsRequested(wallet)
        }
    }

    private func walletSwitcherRow(_ wallet: ManagedWallet) -> some View {
        // A native List button owns selection; List.onMove owns the full cell's
        // long-press lift, drag, cancellation and drop. Keep the accessory separate.
        ZStack(alignment: .trailing) {
            WalletSettingsManagementRow(
                wallet: wallet,
                walletCount: wallets.count,
                isBalanceHidden: applicationSettings.balancePrivacyEnabled
                    || isAppSwitcherPrivacyActive,
                onSelect: { handleRowInteraction(.content, wallet: wallet) }
            )

            walletAccessory(for: wallet)
        }
        .disabled(selectingWalletID != nil)
    }

    private func moveWallets(from source: IndexSet, to destination: Int) {
        guard selectingWalletID == nil else { return }
        wallets.move(fromOffsets: source, toOffset: destination)
        persistReorderedWallets()
    }

    @ViewBuilder
    private func walletAccessory(for wallet: ManagedWallet) -> some View {
        if selectingWalletID == wallet.id {
            ProgressView()
                .controlSize(.regular)
                .tint(WalletTheme.secondaryLabel)
                .frame(width: 28, height: 28)
                .accessibilityLabel(
                    Text("wallet.launch.loading.accessibility")
                )
        } else {
            WalletRowInformationButton {
                handleRowInteraction(.information, wallet: wallet)
            }
            .disabled(selectingWalletID != nil)
        }
    }

    private func persistReorderedWallets() {
        let orderedWalletIDs = wallets.map(\.id)
        Task {
            do {
                try await database.reorderWallets(orderedWalletIDs)
                await MainActor.run {
                    selectionErrorKey = nil
                }
            } catch {
                await loadWalletsAsync()
            }
        }
    }

}

import SwiftUI

struct SettingsBackupWalletSelectionScreen: View {
    let database: WalletDatabase
    let onWalletSelected: (ManagedWallet) -> Void
    let onOnlyWalletSelected: ((ManagedWallet) -> Void)?

    @Environment(WalletSettingsStore.self) private var applicationSettings

    @State private var wallets: [ManagedWallet] = []
    @State private var isLoading = true
    @State private var loadErrorKey: String?
    @State private var didAutomaticallySelectOnlyWallet = false

    init(
        database: WalletDatabase,
        onWalletSelected: @escaping (ManagedWallet) -> Void,
        onOnlyWalletSelected: ((ManagedWallet) -> Void)? = nil
    ) {
        self.database = database
        self.onWalletSelected = onWalletSelected
        self.onOnlyWalletSelected = onOnlyWalletSelected
    }

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
                            WalletSettingsManagementRow(
                                wallet: wallet,
                                walletCount: wallets.count,
                                isBalanceHidden: applicationSettings.balancePrivacyEnabled,
                                reservesAccessorySpace: false,
                                onSelect: {
                                    UniHaptic.play(.selection)
                                    onWalletSelected(wallet)
                                }
                            )
                        }
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .walletPrivacySensitive()
        .navigationTitle("settings.wallets.backup.choose_wallet.title")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadWalletsAsync()
        }
    }

    private func loadWallets() {
        Task { await loadWalletsAsync() }
    }

    @MainActor
    private func loadWalletsAsync() async {
        isLoading = true
        loadErrorKey = nil
        do {
            let loadedWallets = try await database.managedWallets()
                .filter { SettingsBackupAndKeysPolicy.includes($0.kind) }
            try Task.checkCancellation()
            wallets = loadedWallets
            isLoading = false

            guard loadedWallets.count == 1,
                  !didAutomaticallySelectOnlyWallet,
                  let wallet = loadedWallets.first else {
                return
            }
            didAutomaticallySelectOnlyWallet = true
            await Task.yield()
            guard !Task.isCancelled else { return }
            (onOnlyWalletSelected ?? onWalletSelected)(wallet)
        } catch is CancellationError {
        } catch {
            loadErrorKey = "settings.wallets.load.error"
            isLoading = false
        }
    }

}

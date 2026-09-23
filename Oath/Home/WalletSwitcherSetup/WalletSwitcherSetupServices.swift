import Foundation

/// Domain operations only. Presentation and temporary credentials belong to
/// the switcher's setup session, never to the home add-wallet sheet.
@MainActor
struct WalletSwitcherSetupServices {
    var generate: (Data?) async throws -> WalletCreationDraft
    var applyPassphrase: (String, String) async throws -> WalletCreationDraft
    var existingWallet: (WalletImportDraft) async throws -> ManagedWallet?
    var create: (WalletCreationDraft) async throws -> PersistedWalletIdentity
    var importWallet: (
        WalletImportDraft, String?, WalletCloudBackupRemoteIdentity?
    ) async throws -> PersistedWalletIdentity
    var selectWallet: (String) async throws -> PersistedWalletIdentity
    var didPersist: (PersistedWalletIdentity) -> Void

    static func live(database: WalletDatabase) -> Self {
        Self(
            generate: { entropy in
                try await Task.detached(priority: .userInitiated) {
                    if let entropy {
                        return try WalletCoreService.generateEVMWallet(
                            entropy: entropy
                        )
                    }
                    return try WalletCoreService.generateEVMWallet()
                }.value
            },
            applyPassphrase: { mnemonic, passphrase in
                try await Task.detached(priority: .userInitiated) {
                    try WalletCoreService.restoreEVMWallet(
                        mnemonic: mnemonic, passphrase: passphrase
                    )
                }.value
            },
            existingWallet: { try await database.existingWallet(matching: $0) },
            create: {
                try await WalletPersistenceWorker.shared
                    .persistCreatedWallet(
                        database: database,
                        draft: $0,
                        security: .reuseExistingProfile
                    )
            },
            importWallet: { draft, name, cloudIdentity in
                try await WalletPersistenceWorker.shared
                    .persistImportedWallet(
                        database: database,
                        draft: draft,
                        security: .reuseExistingProfile,
                        preferredWalletName: name,
                        cloudBackupIdentity: cloudIdentity
                    )
            },
            selectWallet: { try await database.selectWallet(walletID: $0) },
            didPersist: { identity in
                PushNotificationCoordinator.shared.walletDataDidChange()
            }
        )
    }
}

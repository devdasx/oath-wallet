import SwiftUI

struct WalletSensitiveAccessView: View {
    let database: WalletDatabase
    let wallet: ManagedWallet
    let action: WalletSensitiveAction
    let material: WalletSensitiveMaterial
    let onBackupCompleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var sensitiveLifecycle:
        WalletSensitiveContentLifecycleState

    init(
        database: WalletDatabase,
        wallet: ManagedWallet,
        action: WalletSensitiveAction,
        material: WalletSensitiveMaterial,
        onBackupCompleted: @escaping () -> Void
    ) {
        self.database = database
        self.wallet = wallet
        self.action = action
        self.material = material
        self.onBackupCompleted = onBackupCompleted
        var lifecycle = WalletSensitiveContentLifecycleState()
        _ = lifecycle.acceptLoadedContent()
        _sensitiveLifecycle = State(initialValue: lifecycle)
    }

    var body: some View {
        destination
            .background(WalletTheme.groupedBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isShowingSharedRecoveryPhrase {
                    ToolbarItem(placement: .cancellationAction) {
                        WalletCloseButton {
                            dismiss()
                        }
                    }
                }
            }
            .walletSensitiveContentMask(
                isProtected: sensitiveLifecycle.isMasked,
                requiresProtection: sensitiveLifecycle.isMasked || sensitiveLifecycle.hasExpired
            )
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .inactive:
                    protectSensitiveContent(for: .sceneInactive)
                case .background:
                    protectSensitiveContent(for: .sceneBackground)
                case .active:
                    resumeSensitiveContentAfterInactive()
                @unknown default:
                    protectSensitiveContent(for: .sceneInactive)
                }
            }
            .onDisappear {
                protectSensitiveContent(for: .viewDisappeared)
            }
    }

    @ViewBuilder
    private var destination: some View {
        switch action {
        case .viewRecoveryPhrase:
            if case let .recoveryPhrase(credential) = material {
                WalletRecoveryPhraseDisplayScreen(
                    words: credential.mnemonic
                        .split(whereSeparator: \.isWhitespace)
                        .map(String.init),
                    passphrase: credential.passphrase
                )
            } else {
                WalletManualSecretView(
                    database: database,
                    wallet: wallet,
                    material: material,
                    marksBackupComplete: false,
                    onCompleted: onBackupCompleted
                )
                .navigationTitle(navigationTitle)
            }
        case .manualBackup:
            if case let .recoveryPhrase(credential) = material {
                WalletManualBackupScreen(
                    words: credential.mnemonic
                        .split(whereSeparator: \.isWhitespace)
                        .map(String.init),
                    passphrase: credential.passphrase,
                    onVerified: {
                        try await database.markManualBackupVerified(
                            walletID: wallet.id
                        )
                        await MainActor.run {
                            onBackupCompleted()
                            dismiss()
                        }
                    }
                )
            } else {
                WalletManualSecretView(
                    database: database,
                    wallet: wallet,
                    material: material,
                    marksBackupComplete: true,
                    onCompleted: onBackupCompleted
                )
                .navigationTitle(navigationTitle)
            }
        case .privateKeyExport, .disableICloudBackup:
            // These actions are completed by their owning settings flow.
            EmptyView()
        }
    }

    private var isShowingSharedRecoveryPhrase: Bool {
        switch (action, material) {
        case (.viewRecoveryPhrase, .recoveryPhrase),
             (.manualBackup, .recoveryPhrase):
            true
        default:
            false
        }
    }

    private var navigationTitle: LocalizedStringKey {
        switch action {
        case .viewRecoveryPhrase:
            "settings.wallets.recovery.navigation"
        case .manualBackup:
            "settings.wallets.backup.manual.navigation"
        case .privateKeyExport, .disableICloudBackup:
            "settings.wallets.backup.icloud.navigation"
        }
    }

    @MainActor
    private func protectSensitiveContent(
        for trigger: WalletSensitiveContentLifecycleTrigger
    ) {
        _ = sensitiveLifecycle.protect(for: trigger)
    }

    @MainActor
    private func resumeSensitiveContentAfterInactive() {
        guard sensitiveLifecycle.resumeAfterInactive() else {
            if sensitiveLifecycle.hasExpired { dismiss() }
            return
        }
        _ = sensitiveLifecycle.acceptLoadedContent()
    }
}

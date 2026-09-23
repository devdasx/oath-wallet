import SwiftUI

struct WalletManualSecretView: View {
    let database: WalletDatabase
    let wallet: ManagedWallet
    let material: WalletSensitiveMaterial
    let marksBackupComplete: Bool
    let onCompleted: () -> Void

    @State private var didConfirmBackup = false
    @State private var errorKey: String?

    var body: some View {
        List {
            Group {
                Section {
                    switch material {
                    case let .recoveryPhrase(credential):
                        ForEach(
                            Array(
                                credential.mnemonic
                                    .split(separator: " ")
                                    .enumerated()
                            ),
                            id: \.offset
                        ) { index, word in
                            LabeledContent {
                                Text(verbatim: String(word))
                                    .textSelection(.enabled)
                                    .walletSensitiveValue()
                            } label: {
                                Text(verbatim: String(index + 1))
                            }
                        }
                        if credential.hasPassphrase {
                            LabeledContent(
                                "wallet.recovery.passphrase.section"
                            ) {
                                WalletExactText(credential.passphrase)
                                    .walletSensitiveValue()
                            }
                        }
                    case let .bitcoinImportedWallet(imported):
                        if let data = try? imported.encoded(), let text = String(data: data, encoding: .utf8) {
                            WalletExactText(text).walletSensitiveValue().textSelection(.enabled)
                        }
                    case let .privateKey(key):
                        WalletExactText(key, monospaced: true)
                            .walletSensitiveValue()
                    }
                } header: {
                    Text(materialHeaderKey)
                } footer: {
                    Text("settings.wallets.secret.warning")
                }

                if marksBackupComplete {
                    Section {
                        Button(
                            didConfirmBackup
                                ? LocalizedStringKey(
                                    "settings.wallets.backup.manual.completed"
                                )
                                : LocalizedStringKey(
                                    "settings.wallets.backup.manual.confirm"
                                )
                        , action: UniHaptic.action {
                            confirmBackup()
                        })
                        .disabled(didConfirmBackup)
                    }
                }

                if let errorKey {
                    Section {
                        Text(LocalizedStringKey(errorKey))
                            .foregroundStyle(WalletTheme.danger)
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .walletCallSafetyWarning(.secret)
    }

    private var materialHeaderKey: LocalizedStringKey {
        switch material {
        case .recoveryPhrase:
            "settings.wallets.recovery.words.section"
        case .privateKey, .bitcoinImportedWallet:
            "settings.wallets.private_key.section"
        }
    }

    private func confirmBackup() {
        Task {
            do {
                try await database.markManualBackupVerified(
                    walletID: wallet.id
                )
                didConfirmBackup = true
                onCompleted()
            } catch {
                errorKey = "settings.wallets.backup.manual.error"
            }
        }
    }
}

import SwiftUI
import UIKit

struct WalletSwitcherICloudBackupScreen: View {
    let walletID: String
    let walletName: String?
    let backedUpAt: Date?
    let hasPassphrase: Bool?
    let onRestore: (
        WalletImportDraft,
        String,
        WalletCloudBackupRemoteIdentity
    ) -> Void

    @State private var isRestoring = false
    @State private var errorKey: String?
    @State private var passkeyPresentationWindow: UIWindow?
    @State private var restoreTask: Task<Void, Never>?

    var body: some View {
        List {
            Group {
                Section {
                    LabeledContent("import.icloud.passkey.wallet") {
                        Text(
                            verbatim: walletName
                                ?? WalletLocalization.string(
                                    "import.icloud.backup.title"
                                )
                        )
                        .foregroundStyle(.secondary)
                    }

                    if let backedUpAt {
                        LabeledContent(
                            "settings.wallets.backup.icloud.status"
                        ) {
                            Text(
                                verbatim: EnglishNumbers.dateTime(backedUpAt)
                            )
                            .foregroundStyle(.secondary)
                        }
                    }

                    if hasPassphrase == true {
                        LabeledContent("import.icloud.backup.type") {
                            Text("import.icloud.backup.passphrase_wallet")
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("import.icloud.passkey.footer")
                }

                Section {
                    Button("import.icloud.passkey.restore.action", action: UniHaptic.action {
                        restore()
                    })
                    .disabled(isRestoring)
                }

                if let errorKey {
                    Section {
                        Text(LocalizedStringKey(errorKey))
                            .foregroundStyle(WalletTheme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(WalletTheme.groupedBackground)
        .navigationTitle("import.icloud.passkey.navigation.title")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isRestoring)
        .interactiveDismissDisabled(isRestoring)
        .background {
            WalletPasskeyPresentationAnchorReader { window in
                if passkeyPresentationWindow !== window {
                    passkeyPresentationWindow = window
                }
            }
            .frame(width: 0, height: 0)
        }
        .onDisappear {
            restoreTask?.cancel()
            restoreTask = nil
        }
    }

    private func restore() {
        guard !isRestoring else { return }
        isRestoring = true
        errorKey = nil

        restoreTask = Task { @MainActor in
            defer { isRestoring = false }
            do {
                let restoreResult = try await
                    WalletAutomaticCloudBackupService.shared.restoreResult(
                        walletID: walletID,
                        presentationAnchor: passkeyPresentationWindow
                    )
                let result = try await Task.detached(
                    priority: .userInitiated
                ) {
                    return try ICloudWalletRestoreValidator.validate(
                        restoreResult.payload
                    )
                }.value

                try Task.checkCancellation()
                UniHaptic.play(.success)
                onRestore(
                    result.draft,
                    result.walletName,
                    restoreResult.remoteIdentity
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                handleRestoreFailure(error)
            }
        }
    }

    @MainActor
    private func handleRestoreFailure(_ error: any Error) {
        switch error.walletCloudBackupCategory {
        case .iCloudUnavailable:
            fail(with: "import.icloud.unavailable")
        case .backupNotFound:
            fail(with: "import.icloud.missing.error")
        case .passkeyCanceled:
            isRestoring = false
        case .passkeyDeviceNotConfigured:
            fail(with: "import.icloud.passkey.device.error")
        case .passkeyPRFUnavailable:
            fail(with: "import.icloud.passkey.prf.error")
        case .passkeyPresentationUnavailable:
            fail(with: "import.icloud.passkey.presentation.error")
        case .passkeyCredentialMismatch, .invalidPasskeyCredential:
            fail(with: "import.icloud.passkey.credential.error")
        case .passkeyConfigurationUnavailable,
             .passkeyAuthorizationFailed:
            fail(with: "import.icloud.passkey.request.error")
        case .backupKeyUnavailable, .keychainFailure:
            fail(with: "import.icloud.passkey.unavailable.error")
        case .decryptionFailed, .invalidBackupDocument:
            fail(with: "import.icloud.passkey.decrypt.error")
        default:
            fail(with: "import.icloud.restore.error")
        }
    }

    @MainActor
    private func fail(with key: String) {
        isRestoring = false
        errorKey = key
        UniHaptic.play(.error)
    }
}

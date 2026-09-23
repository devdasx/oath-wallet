import SwiftUI

private enum SettingsWalletCreationDestination: Hashable {
    case passphrase
    case success
}

enum SettingsWalletCreationSecurityMode: Equatable, Sendable {
    case reuseExistingProfile
    case requirePasscodeSetup
}

struct SettingsWalletCreationFlow: View {
    let database: WalletDatabase
    let onCompleted: (String) -> Void
    let onPrepareWalletForOpen: ((String) async -> Bool)?
    let securityMode: SettingsWalletCreationSecurityMode

    @State private var draft: WalletCreationDraft?
    @State private var navigationPath:
        [SettingsWalletCreationDestination] = []
    @State private var createdWalletAddress: String?
    @State private var createdWalletID: String?
    @State private var isSaving = false
    @State private var persistenceFailure: WalletPersistenceFailure?
    @State private var confirmedPasscode: String?
    @State private var isPasscodePresented = false
    @State private var persistsAfterPasscodeDismissal = false
    @State private var passphraseDerivationTask: Task<Void, Never>?
    @Environment(\.openURL) private var openURL

    init(
        database: WalletDatabase,
        draft: WalletCreationDraft,
        securityMode: SettingsWalletCreationSecurityMode =
            .reuseExistingProfile,
        onPrepareWalletForOpen: ((String) async -> Bool)? = nil,
        onCompleted: @escaping (String) -> Void
    ) {
        self.database = database
        self.onCompleted = onCompleted
        self.onPrepareWalletForOpen = onPrepareWalletForOpen
        self.securityMode = securityMode
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack(path: ($navigationPath)) {
            SettingsWalletCreationRecoveryScreen(
                words: draft?.words ?? [],
                hasPassphrase: !(draft?.passphrase.isEmpty ?? true),
                isSaving: isSaving,
                onManagePassphrase: {
                    navigationPath.append(.passphrase)
                },
                onContinue: continueAfterRecoveryPhrase
            )
            .navigationDestination(
                for: SettingsWalletCreationDestination.self
            ) { destination in
                switch destination {
                case .passphrase:
                    SettingsWalletCreationPassphraseScreen(
                        initialPassphrase: draft?.passphrase ?? "",
                        onSave: applyPassphrase
                    )
                case .success:
                    SettingsWalletCreationSuccessScreen(
                        isReady: createdWalletAddress != nil,
                        backupContext: createdWalletID.map {
                            WalletSuccessBackupContext(database: database, walletID: $0)
                        },
                        onPrepare: startWalletPreparation,
                        onDone: {
                            guard let createdWalletAddress else { return }
                            onCompleted(createdWalletAddress)
                        }
                    )
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .fullScreenCover(
            isPresented: $isPasscodePresented,
            onDismiss: finishPasscodeDismissal
        ) {
            WalletAuthenticationFullScreenContainer(
                title: "passcode.navigation.set"
            ) {
                PINSetupFlowView { passcode in
                    confirmedPasscode = passcode
                    persistsAfterPasscodeDismissal = true
                    isPasscodePresented = false
                }
            }
        }
        .alert(
            "wallet.creation.error.title",
            isPresented: Binding(
                get: { persistenceFailure != nil },
                set: { isPresented in
                    if !isPresented {
                        persistenceFailure = nil
                    }
                }
            )
        ) {
            Button("import.saving.retry", action: UniHaptic.action(startWalletPreparation))

            if let supportURL = persistenceFailure?.supportURL {
                Button("wallet.persistence.contact_support", action: UniHaptic.action(nil) {
                    openURL(supportURL)
                })
            }

            Button("common.cancel", role: .cancel, action: UniHaptic.action {
                cancelFailedPreparation()
            })
        } message: {
            if let persistenceFailure {
                Text(
                    verbatim: persistenceFailureMessage(
                        persistenceFailure
                    )
                )
            }
        }
    }

    @MainActor
    private func continueAfterRecoveryPhrase() {
        guard draft != nil else { return }

        switch securityMode {
        case .reuseExistingProfile:
            showSuccess()
        case .requirePasscodeSetup:
            guard !isPasscodePresented else { return }
            persistsAfterPasscodeDismissal = false
            isPasscodePresented = true
        }
    }

    @MainActor
    private func finishPasscodeDismissal() {
        guard persistsAfterPasscodeDismissal else { return }
        persistsAfterPasscodeDismissal = false
        showSuccess()
    }

    @MainActor
    private func applyPassphrase(_ passphrase: String) {
        guard let draft, passphraseDerivationTask == nil else { return }
        passphraseDerivationTask = Task { @MainActor in
            defer { passphraseDerivationTask = nil }
            do {
                let updated = try await Task.detached(
                    priority: .userInitiated
                ) {
                    try WalletCoreService.restoreEVMWallet(
                        mnemonic: draft.mnemonic,
                        passphrase: passphrase
                    )
                }.value
                try Task.checkCancellation()
                self.draft = updated
                navigationPath.removeLast()
            } catch is CancellationError {
                return
            } catch {
                UniHaptic.play(.error)
                persistenceFailure = WalletPersistenceFailure(error: error)
            }
        }
    }

    @MainActor
    private func showSuccess() {
        guard draft != nil,
              navigationPath.last != .success else { return }
        createdWalletAddress = nil
        createdWalletID = nil
        persistenceFailure = nil
        navigationPath.append(.success)
    }

    @MainActor
    private func startWalletPreparation() {
        guard !isSaving else { return }
        guard createdWalletAddress == nil else { return }
        isSaving = true
        persistenceFailure = nil

        Task { @MainActor in
            do {
                try await persistWallet()
                isSaving = false
                if let address = createdWalletAddress, let onPrepareWalletForOpen {
                    _ = await onPrepareWalletForOpen(address)
                }
            } catch {
                UniHaptic.play(.error)
                persistenceFailure = WalletPersistenceFailure(
                    error: error
                )
                isSaving = false
            }
        }
    }

    @MainActor
    private func cancelFailedPreparation() {
        guard !isSaving,
              createdWalletAddress == nil,
              navigationPath.last == .success else { return }
        navigationPath.removeLast()
    }

    private func persistWallet() async throws {
        guard let draft else {
            throw WalletCreationPersistenceError.invalidDraft
        }

        let persistenceSecurity: WalletPersistenceSecurity
        switch securityMode {
        case .reuseExistingProfile:
            persistenceSecurity = .reuseExistingProfile
        case .requirePasscodeSetup:
            guard let confirmedPasscode, !confirmedPasscode.isEmpty else {
                throw WalletCreationPersistenceError.invalidPasscode
            }
            persistenceSecurity = .establishOrVerify(
                passcode: confirmedPasscode,
                biometricEnabled: false
            )
        }

        let identity = try await WalletPersistenceWorker.shared
            .persistCreatedWallet(
                database: database,
                draft: draft,
                security: persistenceSecurity
            )
        await MainActor.run {
            PushNotificationCoordinator.shared
                .walletDataDidChange()
            createdWalletID = identity.walletID
            createdWalletAddress = identity.address
        }
    }

    private func persistenceFailureMessage(
        _ failure: WalletPersistenceFailure
    ) -> String {
        [
            WalletLocalization.string(failure.messageKey),
            EnglishNumbers.localized(
                "wallet.persistence.support.hint",
                WalletSupport.emailAddress
            ),
            EnglishNumbers.localized(
                "wallet.persistence.error.reference",
                failure.diagnosticCode
            )
        ]
        .joined(separator: "\n\n")
    }
}

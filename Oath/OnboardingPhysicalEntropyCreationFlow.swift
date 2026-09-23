import SwiftUI

enum OnboardingPhysicalEntropyDestination: Hashable {
    case input
    case recoveryPhrase
    case passphrase
    case wordList
    case passcode
    case persistenceFailure(WalletPersistenceFailure)
    case success
}

enum OnboardingPhysicalEntropyPassphraseDerivation {
    static func updatedDraft(
        from draft: WalletCreationDraft,
        passphrase: String
    ) throws -> WalletCreationDraft {
        let updatedDraft = try WalletCoreService.restoreEVMWallet(
            mnemonic: draft.mnemonic,
            passphrase: passphrase
        )
        guard updatedDraft.mnemonic == draft.mnemonic,
              updatedDraft.words == draft.words else {
            throw WalletCreationPersistenceError.invalidDraft
        }
        return updatedDraft
    }
}

enum OnboardingPhysicalEntropyStep: Equatable, Sendable {
    case entropy
    case recoveryPhrase
    case passcode
}

enum OnboardingPhysicalEntropyNavigation {
    static let initialDestination:
        OnboardingPhysicalEntropyDestination = .input

    static func destination(
        after step: OnboardingPhysicalEntropyStep
    ) -> OnboardingPhysicalEntropyDestination {
        switch step {
        case .entropy:
            .recoveryPhrase
        case .recoveryPhrase:
            .passcode
        case .passcode:
            .success
        }
    }
}

@MainActor
@Observable
final class OnboardingPhysicalEntropyCreationSession {
    let database: WalletDatabase
    let usesExistingProfileSecurity: Bool
    private let onPrepareWalletForOpen: ((String) async -> Bool)?

    private(set) var creationDraft: WalletCreationDraft?
    private(set) var confirmedPasscode = ""
    private(set) var createdWalletAddress: String?
    private(set) var createdWalletID: String?
    private(set) var generationErrorMessage: String?
    private(set) var generationTask: Task<Void, Never>?
    private(set) var persistenceTask: Task<Void, Never>?

    init(
        database: WalletDatabase,
        usesExistingProfileSecurity: Bool = false,
        onPrepareWalletForOpen: ((String) async -> Bool)? = nil
    ) {
        self.database = database
        self.usesExistingProfileSecurity = usesExistingProfileSecurity
        self.onPrepareWalletForOpen = onPrepareWalletForOpen
    }

    var words: [String] {
        creationDraft?.words ?? []
    }

    var passphrase: String {
        creationDraft?.passphrase ?? ""
    }

    var isGeneratingWallet: Bool {
        generationTask != nil
    }

    var isPersistingWallet: Bool {
        persistenceTask != nil
    }

    func generateWallet(
        _ entropy: Data,
        onNavigate: @escaping @MainActor @Sendable (
            OnboardingPhysicalEntropyDestination
        ) -> Void
    ) {
        guard generationTask == nil else { return }
        generationErrorMessage = nil

        generationTask = Task { @MainActor in
            defer { generationTask = nil }

            do {
                let draft = try await Task.detached(
                    priority: .userInitiated
                ) {
                    try WalletCoreService.generateEVMWallet(
                        entropy: entropy
                    )
                }.value
                try Task.checkCancellation()
                guard draft.words.count == 24 else {
                    throw WalletCreationPersistenceError.invalidDraft
                }

                creationDraft = draft
                confirmedPasscode = ""
                generationErrorMessage = nil
                onNavigate(
                    OnboardingPhysicalEntropyNavigation.destination(
                        after: .entropy
                    )
                )
                UniHaptic.play(.successQuiet)
            } catch is CancellationError {
                return
            } catch {
                UniHaptic.play(.error)
                generationErrorMessage = WalletLocalization.string(
                    "wallet.creation.generate.error"
                )
            }
        }
    }

    func updatePassphrase(_ passphrase: String) async throws {
        guard let currentDraft = creationDraft else {
            throw WalletCreationPersistenceError.invalidDraft
        }

        let updatedDraft = try await Task.detached(
            priority: .userInitiated
        ) {
            try OnboardingPhysicalEntropyPassphraseDerivation.updatedDraft(
                from: currentDraft,
                passphrase: passphrase
            )
        }.value
        try Task.checkCancellation()

        guard creationDraft?.mnemonic == currentDraft.mnemonic else {
            throw WalletCreationPersistenceError.invalidDraft
        }
        creationDraft = updatedDraft
    }

    func persistWallet(
        _ passcode: String,
        onNavigate: @escaping @MainActor @Sendable (
            OnboardingPhysicalEntropyDestination
        ) -> Void
    ) {
        guard persistenceTask == nil else { return }
        confirmedPasscode = passcode
        onNavigate(.success)
    }

    func continueAfterRecoveryPhrase(
        onNavigate: @escaping @MainActor @Sendable (
            OnboardingPhysicalEntropyDestination
        ) -> Void
    ) {
        guard creationDraft != nil, persistenceTask == nil else { return }
        if usesExistingProfileSecurity {
            onNavigate(.success)
        } else {
            onNavigate(
                OnboardingPhysicalEntropyNavigation.destination(
                    after: .recoveryPhrase
                )
            )
        }
    }

    func retryPersistence(
        onNavigate: @escaping @MainActor @Sendable (
            OnboardingPhysicalEntropyDestination
        ) -> Void
    ) {
        guard persistenceTask == nil,
              usesExistingProfileSecurity || !confirmedPasscode.isEmpty else {
            return
        }
        onNavigate(.success)
    }

    func prepareWallet(
        onNavigate: @escaping @MainActor @Sendable (
            OnboardingPhysicalEntropyDestination
        ) -> Void
    ) {
        guard createdWalletAddress == nil else { return }
        startPersistence(onNavigate: onNavigate)
    }

    func resetPasscode() {
        confirmedPasscode = ""
    }

    func cancelOwnedWork() {
        generationTask?.cancel()
        generationTask = nil
        persistenceTask?.cancel()
        persistenceTask = nil
        creationDraft = nil
        createdWalletAddress = nil
        createdWalletID = nil
        generationErrorMessage = nil
        resetPasscode()
    }

    private func startPersistence(
        onNavigate: @escaping @MainActor @Sendable (
            OnboardingPhysicalEntropyDestination
        ) -> Void
    ) {
        guard persistenceTask == nil else { return }

        persistenceTask = Task { @MainActor in
            defer { persistenceTask = nil }

            do {
                let address = try await persistCreatedWallet()
                try Task.checkCancellation()
                createdWalletAddress = address
                creationDraft = nil
                resetPasscode()
                if let onPrepareWalletForOpen {
                    _ = await onPrepareWalletForOpen(address)
                }
            } catch is CancellationError {
                return
            } catch {
                UniHaptic.play(.error)
                onNavigate(
                    .persistenceFailure(
                        WalletPersistenceFailure(error: error)
                    )
                )
            }
        }
    }

    private func persistCreatedWallet() async throws -> String {
        guard let creationDraft else {
            throw WalletCreationPersistenceError.invalidDraft
        }

        let identity = try await WalletPersistenceWorker.shared
            .persistCreatedWallet(
                database: database,
                draft: creationDraft,
                security: try persistenceSecurity
            )

        await MainActor.run {
            PushNotificationCoordinator.shared.walletDataDidChange()
        }
        createdWalletID = identity.walletID
        return identity.address
    }

    var persistenceSecurity: WalletPersistenceSecurity {
        get throws {
            if usesExistingProfileSecurity {
                return .reuseExistingProfile
            }
            guard !confirmedPasscode.isEmpty else {
                throw WalletCreationPersistenceError.invalidPasscode
            }
            return .establishOrVerify(
                passcode: confirmedPasscode,
                biometricEnabled: false
            )
        }
    }
}

struct OnboardingPhysicalEntropyCreationFlow: View {
    let destination: OnboardingPhysicalEntropyDestination
    @Bindable var session: OnboardingPhysicalEntropyCreationSession
    let onNavigate: @MainActor @Sendable (
        OnboardingPhysicalEntropyDestination
    ) -> Void
    let onReturnToRecoveryPhrase: @MainActor @Sendable () -> Void
    let onCompleted: @MainActor @Sendable (String) -> Void

    @ViewBuilder
    var body: some View {
        switch destination {
        case .input:
            OnboardingPhysicalEntropyInputScreen(
                isGeneratingWallet: session.isGeneratingWallet,
                errorMessage: session.generationErrorMessage,
                onComplete: { entropy in
                    session.generateWallet(
                        entropy,
                        onNavigate: onNavigate
                    )
                }
            )

        case .recoveryPhrase:
            OnboardingPhysicalEntropyRecoveryScreen(
                words: session.words,
                hasPassphrase: !session.passphrase.isEmpty,
                isSaving: session.isPersistingWallet,
                onManagePassphrase: {
                    onNavigate(.passphrase)
                },
                onViewWordList: {
                    onNavigate(.wordList)
                },
                onContinue: {
                    session.continueAfterRecoveryPhrase(onNavigate: onNavigate)
                }
            )

        case .passphrase:
            OnboardingPhysicalEntropyPassphraseScreen(
                initialPassphrase: session.passphrase,
                onSave: { passphrase in
                    try await session.updatePassphrase(passphrase)
                }
            )

        case .wordList:
            OnboardingPhysicalEntropyWordListScreen()

        case .passcode:
            OnboardingPhysicalEntropyPasscodeScreen(
                isSaving: session.isPersistingWallet,
                onPasscodeConfirmed: { passcode in
                    session.persistWallet(
                        passcode,
                        onNavigate: onNavigate
                    )
                }
            )

        case let .persistenceFailure(failure):
            OnboardingPhysicalEntropyPersistenceFailureScreen(
                failure: failure,
                isRetrying: session.isPersistingWallet,
                onRetry: {
                    session.retryPersistence(onNavigate: onNavigate)
                },
                onBackToRecoveryPhrase: {
                    session.resetPasscode()
                    onReturnToRecoveryPhrase()
                }
            )

        case .success:
            OnboardingPhysicalEntropySuccessScreen(
                isReady: session.createdWalletAddress != nil,
                backupContext: session.createdWalletID.map {
                    WalletSuccessBackupContext(database: session.database, walletID: $0)
                },
                onPrepare: {
                    session.prepareWallet(onNavigate: onNavigate)
                },
                onContinue: {
                    guard let address = session.createdWalletAddress,
                          !address.isEmpty else {
                        return
                    }
                    onCompleted(address)
                }
            )
        }
    }
}

import Foundation
import Observation

@MainActor
@Observable
final class WalletSwitcherSetupSession {
    private(set) var creationDraft: WalletCreationDraft?
    private(set) var generationFailure: WalletPersistenceFailure?
    private(set) var isGenerating = false
    private(set) var isCheckingImport = false
    private(set) var isCommitting = false
    private(set) var isFinishing = false
    private(set) var isReady = false
    private(set) var allowsManualBackup = true
    private(set) var duplicate: DuplicateWalletImportWarning?
    private(set) var identity: PersistedWalletIdentity?
    var importFailure: WalletPersistenceFailure?
    var completionFailed = false

    @ObservationIgnored private let services: WalletSwitcherSetupServices
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var entropy: Data?
    @ObservationIgnored private var pendingImport: PendingImport?

    private struct PendingImport {
        let draft: WalletImportDraft
        let name: String?
        let cloudIdentity: WalletCloudBackupRemoteIdentity?
    }

    init(services: WalletSwitcherSetupServices) {
        self.services = services
    }

    func beginCreation(entropy: Data? = nil) {
        reset()
        self.entropy = entropy
    }

    func prepareCreation() async {
        guard creationDraft == nil, !isGenerating else { return }
        let request = generation
        isGenerating = true
        generationFailure = nil
        defer {
            if request == generation { isGenerating = false }
        }
        do {
            let draft = try await services.generate(entropy)
            try Task.checkCancellation()
            guard request == generation else { return }
            creationDraft = draft
            entropy = nil
        } catch is CancellationError {
            return
        } catch {
            guard request == generation else { return }
            generationFailure = WalletPersistenceFailure(error: error)
        }
    }

    func applyPassphrase(_ passphrase: String) async throws {
        guard let creationDraft else {
            throw WalletCreationPersistenceError.invalidDraft
        }
        let request = generation
        let updated = try await services.applyPassphrase(
            creationDraft.mnemonic, passphrase
        )
        try Task.checkCancellation()
        guard request == generation else { throw CancellationError() }
        self.creationDraft = updated
    }

    func prepareImport(
        _ draft: WalletImportDraft,
        restoredName: String? = nil,
        cloudIdentity: WalletCloudBackupRemoteIdentity? = nil
    ) async -> WalletSwitcherImportPreparation? {
        guard !isCheckingImport else { return nil }
        let request = generation
        isCheckingImport = true
        importFailure = nil
        defer {
            if request == generation { isCheckingImport = false }
        }
        do {
            let name = try Self.preferredName(restoredName)
            let existing = try await services.existingWallet(draft)
            try Task.checkCancellation()
            guard request == generation else { return nil }
            if let existing {
                duplicate = DuplicateWalletImportWarning(wallet: existing)
                return .duplicateImport
            }
            allowsManualBackup = draft.hasRecoveryPhrase
            pendingImport = PendingImport(
                draft: draft, name: name, cloudIdentity: cloudIdentity
            )
            return .readyToPersist
        } catch is CancellationError {
            return nil
        } catch {
            guard request == generation else { return nil }
            importFailure = WalletPersistenceFailure(error: error)
            return nil
        }
    }

    func commit() async throws {
        // A successful commit must never be replayed on view reappearance.
        guard identity == nil else { return }
        guard !isCommitting else { throw CancellationError() }
        let request = generation
        isCommitting = true
        defer { isCommitting = false }
        let saved: PersistedWalletIdentity
        if let creationDraft {
            saved = try await services.create(creationDraft)
        } else if let pendingImport {
            saved = try await services.importWallet(
                pendingImport.draft,
                pendingImport.name,
                pendingImport.cloudIdentity
            )
        } else {
            throw WalletCreationPersistenceError.invalidDraft
        }
        services.didPersist(saved)
        guard request == generation else { throw CancellationError() }
        identity = saved
        self.creationDraft = nil
        pendingImport = nil
        entropy = nil
        try Task.checkCancellation()
    }

    func finish(
        onWalletAdded: (String) async -> Bool
    ) async -> Bool {
        if isReady { return true }
        guard !isFinishing else { return false }
        let request = generation
        isFinishing = true
        completionFailed = false
        defer {
            if request == generation { isFinishing = false }
        }
        do {
            let selected: PersistedWalletIdentity
            if let identity {
                selected = identity
            } else if let duplicate {
                selected = try await services.selectWallet(duplicate.wallet.id)
                guard request == generation else { return false }
                identity = selected
            } else {
                throw WalletCreationPersistenceError.invalidDraft
            }
            try Task.checkCancellation()
            let ready = await onWalletAdded(selected.address)
            guard !Task.isCancelled, request == generation else { return false }
            isReady = ready
            completionFailed = !ready
            return ready
        } catch is CancellationError {
            return false
        } catch {
            guard request == generation else { return false }
            importFailure = WalletPersistenceFailure(error: error)
            return false
        }
    }

    func didNavigateBack(to routes: [WalletSwitcherSetupRoute]) {
        generation = UUID()
        isGenerating = false
        isCheckingImport = false
        isCommitting = false
        isFinishing = false
        isReady = false
        importFailure = nil
        completionFailed = false
        if !routes.contains(.recovery) {
            creationDraft = nil
            entropy = nil
            generationFailure = nil
        }
        pendingImport = nil
        // Returning to editable input starts a new import, even if a
        // duplicate wallet was selected before Home became ready.
        identity = nil
        if !routes.contains(.duplicateImport) { duplicate = nil }
        if routes.isEmpty { reset() }
    }

    func reset() {
        allowsManualBackup = true
        generation = UUID()
        creationDraft = nil
        entropy = nil
        pendingImport = nil
        duplicate = nil
        identity = nil
        generationFailure = nil
        importFailure = nil
        completionFailed = false
        isGenerating = false
        isCheckingImport = false
        isCommitting = false
        isFinishing = false
        isReady = false
    }

    private static func preferredName(_ restoredName: String?) throws -> String? {
        guard let restoredName else { return nil }
        guard let name = WalletDefaultName.normalizedCustomName(restoredName) else {
            throw WalletCreationPersistenceError.invalidDraft
        }
        return WalletDefaultName.isLegacyGenericName(name) ? nil : name
    }
}

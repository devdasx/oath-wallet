import Foundation
import Testing
@testable import Aperture

@MainActor
@Suite(.serialized)
struct WalletSwitcherSetupSessionTests {
    @Test(arguments: [false, true])
    func importBackupOptionsAreKnownBeforeSavingAndSurviveCommit(privateKey: Bool) async throws {
        let phrase = try WalletSwitcherSetupTestFixtures.imported()
        let draft = privateKey ? WalletImportDraft(
            secret: .privateKey(data: Data(repeating: 1, count: 32), network: .evm, format: .rawSecp256k1),
            address: phrase.address, normalizedAddress: phrase.normalizedAddress,
            derivationPath: nil, publicKey: phrase.publicKey
        ) : phrase
        let session = WalletSwitcherSetupSession(services: WalletSwitcherSetupTestFixtures.services())
        #expect(await session.prepareImport(draft) == .readyToPersist)
        #expect(session.allowsManualBackup == !privateKey)
        try await session.commit()
        #expect(session.allowsManualBackup == !privateKey)
        session.beginCreation()
        #expect(session.allowsManualBackup)
    }

    @Test
    func entryRoutesStayInsideTheSwitcherFlow() {
        #expect(WalletSwitcherSetupRoute.entry(for: .create) == .recovery)
        #expect(WalletSwitcherSetupRoute.entry(for: .importWallet) == .importOptions)
        #expect(WalletSwitcherSetupRoute.entry(for: .restoreICloud) == .restoreICloud)
        #expect(
            WalletSwitcherImportPreparation.readyToPersist.destination
                == .success
        )
        #expect(
            WalletSwitcherImportPreparation.duplicateImport.destination
                == .duplicateImport
        )
    }

    @Test(arguments: [false, true])
    func creationRetainsItsDraftAcrossBackNavigationAndCommitsOnlyOnce(customEntropy: Bool) async throws {
        var services = WalletSwitcherSetupTestFixtures.services()
        var savedDrafts: [WalletCreationDraft] = []
        var persisted: [PersistedWalletIdentity] = []
        services.create = {
            savedDrafts.append($0)
            return PersistedWalletIdentity(walletID: "new-wallet", address: $0.address)
        }
        services.didPersist = { persisted.append($0) }
        let session = WalletSwitcherSetupSession(services: services)
        session.beginCreation(entropy: customEntropy ? Data(repeating: 0, count: 32) : nil)
        await session.prepareCreation()
        let original = try #require(session.creationDraft)
        #expect(original.words.count == (customEntropy ? 24 : 12))
        try await session.applyPassphrase("public-test-passphrase")
        let updated = try #require(session.creationDraft)
        #expect(updated.mnemonic == original.mnemonic)
        #expect(updated.address != original.address)

        session.didNavigateBack(to: [.recovery])
        await session.prepareCreation()
        #expect(session.creationDraft == updated)
        try await session.commit()
        try await session.commit()
        #expect(savedDrafts == [updated])
        #expect(persisted.count == 1)
        #expect(session.creationDraft == nil)
        #expect(session.identity?.address == updated.address)
        #expect(!session.isCommitting)
    }

    @Test
    func backingOutDiscardsLateGenerationInsteadOfOpeningAnotherFlow() async throws {
        let gate = WalletSwitcherTestGate<WalletCreationDraft>()
        var services = WalletSwitcherSetupTestFixtures.services()
        services.generate = { _ in await gate.wait() }
        let session = WalletSwitcherSetupSession(services: services)
        let task = Task { await session.prepareCreation() }
        while !gate.isWaiting { await Task.yield() }
        session.didNavigateBack(to: [])
        gate.resume(try WalletSwitcherSetupTestFixtures.creation())
        await task.value
        #expect(session.creationDraft == nil)
        #expect(session.generationFailure == nil)
        #expect(!session.isGenerating)
        #expect(session.identity == nil)
    }

    @Test
    func failedCreationCanRetryWithoutLeavingTheSheet() async throws {
        var services = WalletSwitcherSetupTestFixtures.services()
        var attempts = 0
        services.create = {
            attempts += 1
            if attempts == 1 { throw WalletCreationPersistenceError.missingSecret }
            return PersistedWalletIdentity(walletID: "retry", address: $0.address)
        }
        let session = WalletSwitcherSetupSession(services: services)
        await session.prepareCreation()
        await #expect(throws: WalletCreationPersistenceError.self) {
            try await session.commit()
        }
        #expect(session.creationDraft != nil)
        #expect(session.identity == nil)
        #expect(!session.isCommitting)
        try await session.commit()
        #expect(attempts == 2)
        #expect(session.identity?.walletID == "retry")
    }

    @Test
    func restoredImportPreservesExactCredentialsAndWalletName() async throws {
        let draft = try WalletSwitcherSetupTestFixtures.imported()
        var services = WalletSwitcherSetupTestFixtures.services()
        var receivedDraft: WalletImportDraft?
        var receivedName: String?
        services.importWallet = { incoming, name, _ in
            receivedDraft = incoming
            receivedName = name
            return PersistedWalletIdentity(walletID: "restored", address: incoming.address)
        }
        let session = WalletSwitcherSetupSession(services: services)
        #expect(
            await session.prepareImport(
                draft,
                restoredName: "  My Restored Wallet  "
            ) == .readyToPersist
        )
        try await session.commit()
        #expect(receivedDraft == draft)
        #expect(receivedName == "My Restored Wallet")
        #expect(session.identity?.address == draft.address)
    }

    @Test
    func duplicateImportActivatesExistingWalletWithoutCreatingAnother() async throws {
        var services = WalletSwitcherSetupTestFixtures.services()
        var imports = 0
        var selected: [String] = []
        services.existingWallet = { _ in NativeListTestFixtures.wallet }
        services.importWallet = { draft, _, _ in
            imports += 1
            return PersistedWalletIdentity(walletID: "unexpected", address: draft.address)
        }
        services.selectWallet = {
            selected.append($0)
            return PersistedWalletIdentity(walletID: $0, address: NativeListTestFixtures.address)
        }
        let session = WalletSwitcherSetupSession(services: services)
        #expect(await session.prepareImport(try WalletSwitcherSetupTestFixtures.imported()) == .duplicateImport)
        #expect(await session.finish { $0 == NativeListTestFixtures.address })
        #expect(imports == 0)
        #expect(selected == [NativeListTestFixtures.wallet.id])
    }

    @Test
    func choosingDifferentCredentialsAfterDuplicateActivationDoesNotReuseThatWallet() async throws {
        var services = WalletSwitcherSetupTestFixtures.services()
        var lookups = 0
        var importedDrafts: [WalletImportDraft] = []
        services.existingWallet = { _ in
            lookups += 1
            return lookups == 1 ? NativeListTestFixtures.wallet : nil
        }
        services.importWallet = { draft, _, _ in
            importedDrafts.append(draft)
            return PersistedWalletIdentity(walletID: "different-wallet", address: draft.address)
        }
        let session = WalletSwitcherSetupSession(services: services)
        #expect(await session.prepareImport(try WalletSwitcherSetupTestFixtures.imported()) == .duplicateImport)
        #expect(!(await session.finish { _ in false }))
        #expect(session.identity?.walletID == NativeListTestFixtures.wallet.id)

        session.didNavigateBack(to: [.importOptions, .importRecoveryPhrase])
        #expect(session.identity == nil)
        let differentDraft = try WalletSwitcherSetupTestFixtures.imported(passphrase: "public-different-wallet")
        #expect(
            await session.prepareImport(differentDraft)
                == .readyToPersist
        )
        try await session.commit()
        #expect(importedDrafts == [differentDraft])
        #expect(session.identity?.walletID == "different-wallet")
        #expect(session.identity?.address == differentDraft.address)
    }

    @Test
    func successfulSetupWaitsForHomeReadinessAndCanRetryCompletion() async throws {
        let session = WalletSwitcherSetupSession(services: WalletSwitcherSetupTestFixtures.services())
        await session.prepareCreation()
        try await session.commit()
        let saved = try #require(session.identity)
        #expect(!(await session.finish { _ in false }))
        #expect(session.completionFailed)
        #expect(!session.isReady)
        #expect(session.identity == saved)
        #expect(await session.finish { $0 == saved.address })
        #expect(!session.completionFailed)
        #expect(session.isReady)
        #expect(!session.isFinishing)
    }

    @Test
    func preparedWalletReadinessIsReusedWithoutASecondHomeActivation() async throws {
        let session = WalletSwitcherSetupSession(
            services: WalletSwitcherSetupTestFixtures.services()
        )
        await session.prepareCreation()
        try await session.commit()
        var activations = 0

        #expect(await session.finish { _ in
            activations += 1
            return true
        })
        #expect(await session.finish { _ in
            Issue.record("Done must reuse the activation started for Success")
            return true
        })
        #expect(activations == 1)
    }

    @Test
    func doneCannotDismissOrStartAnotherCompletionUntilTheWalletIsReady() async throws {
        let session = WalletSwitcherSetupSession(services: WalletSwitcherSetupTestFixtures.services())
        await session.prepareCreation()
        try await session.commit()
        let gate = WalletSwitcherTestGate<Bool>()
        var completedAddresses: [String] = []
        let completion = Task {
            await session.finish { address in
                completedAddresses.append(address)
                return await gate.wait()
            }
        }
        while !gate.isWaiting { await Task.yield() }
        #expect(session.isFinishing)
        #expect(!(await session.finish { _ in
            Issue.record("A repeated Done action must not start a second completion")
            return true
        }))
        gate.resume(true)
        #expect(await completion.value)
        #expect(completedAddresses == [try WalletSwitcherSetupTestFixtures.creation().address])
        #expect(!session.isFinishing)
    }

    @Test
    func cancelledCompletionDoesNotRequestDismissal() async throws {
        let session = WalletSwitcherSetupSession(services: WalletSwitcherSetupTestFixtures.services())
        await session.prepareCreation()
        try await session.commit()
        let gate = WalletSwitcherTestGate<Bool>()
        let completion = Task {
            await session.finish { _ in await gate.wait() }
        }
        while !gate.isWaiting { await Task.yield() }
        completion.cancel()
        gate.resume(true)
        #expect(!(await completion.value))
        #expect(!session.isFinishing)
        #expect(!session.completionFailed)
    }

    @Test
    func lateImportValidationCannotReplaceTheCurrentScreen() async throws {
        let gate = WalletSwitcherTestGate<ManagedWallet?>()
        var services = WalletSwitcherSetupTestFixtures.services()
        services.existingWallet = { _ in await gate.wait() }
        let session = WalletSwitcherSetupSession(services: services)
        let draft = try WalletSwitcherSetupTestFixtures.imported()
        let task = Task { await session.prepareImport(draft) }
        while !gate.isWaiting { await Task.yield() }
        session.didNavigateBack(to: [.importOptions])
        gate.resume(nil)
        #expect(await task.value == nil)
        #expect(session.duplicate == nil)
        #expect(session.importFailure == nil)
        #expect(!session.isCheckingImport)
        await #expect(throws: WalletCreationPersistenceError.self) { try await session.commit() }
    }

    @Test
    func simultaneousCommitCannotAdvanceBeforePersistenceFinishes() async throws {
        let gate = WalletSwitcherTestGate<PersistedWalletIdentity>()
        var services = WalletSwitcherSetupTestFixtures.services()
        services.create = { _ in await gate.wait() }
        let session = WalletSwitcherSetupSession(services: services)
        await session.prepareCreation()
        let task = Task { try await session.commit() }
        while !gate.isWaiting { await Task.yield() }
        await #expect(throws: CancellationError.self) { try await session.commit() }
        #expect(session.identity == nil)
        gate.resume(PersistedWalletIdentity(walletID: "saved", address: NativeListTestFixtures.address))
        try await task.value
        #expect(session.identity?.walletID == "saved")
    }
}

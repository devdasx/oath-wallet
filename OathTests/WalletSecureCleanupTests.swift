import Foundation
import GRDB
import Testing
@testable import Aperture

@Suite(.serialized)
struct WalletSecureCleanupTests {
    @Test
    func appResetCommitsDeletionAndCleanupJournalTogether()
        async throws
    {
        let database = try WalletDatabase.temporary()
        try await seedWallet(in: database)
        let operationID = UUID()

        let commit = try await database.commitAppReset(
            cleanupPlan: WalletAppResetCleanupPlan(
                secretReferences: [
                    "opaque-wallet-secret",
                    "opaque-passcode"
                ],
                requiresPushCleanup: true
            ),
            operationID: operationID
        )

        #expect(commit.operationID == operationID)
        #expect(try await walletCount(in: database) == 0)
        let operation = try #require(
            try await database.secureCleanupOperation(id: operationID)
        )
        #expect(
            operation.scope == WalletSecureCleanupScope.appReset.rawValue
        )
        #expect(
            operation.cleanupState
                == WalletSecureCleanupState.pending.rawValue
        )
        #expect(
            operation.maintenanceState
                == WalletSecureCleanupMaintenanceState.pending.rawValue
        )

        let jobs = try await database.pendingSecureCleanupJobs(
            operationID: operationID
        )
        #expect(jobs.count == 3)
        #expect(
            Set(jobs.map(\.kind)) == [
                WalletSecureCleanupJobKind.walletSecret.rawValue,
                WalletSecureCleanupJobKind.pushInstallation.rawValue
            ]
        )
        #expect(
            Set(jobs.compactMap(\.opaqueReference)) == [
                "opaque-wallet-secret",
                "opaque-passcode"
            ]
        )
    }

    @Test
    func failedResetTransactionCreatesNoCleanupJournal()
        async throws
    {
        let database = try WalletDatabase.temporary()
        try await seedWallet(in: database)
        try await database.pool.write { db in
            try db.execute(
                sql: """
                CREATE TRIGGER preserve_wallet_during_atomic_reset
                BEFORE DELETE ON wallets
                BEGIN
                    SELECT RAISE(IGNORE);
                END
                """
            )
        }
        let operationID = UUID()

        do {
            _ = try await database.commitAppReset(
                cleanupPlan: WalletAppResetCleanupPlan(
                    secretReferences: ["opaque-wallet-secret"],
                    requiresPushCleanup: true
                ),
                operationID: operationID
            )
            Issue.record("Reset unexpectedly committed.")
        } catch is WalletDatabaseResetError {
            // Expected: verification runs in the same GRDB transaction.
        } catch is DatabaseError {
            // SQLite may reject the retained wallet at the foreign-key
            // boundary before residual verification. The assertions below
            // still prove that the transaction and cleanup journal rolled
            // back atomically.
        } catch {
            Issue.record("Unexpected reset error: \(type(of: error))")
        }

        #expect(try await walletCount(in: database) == 1)
        #expect(
            try await database.secureCleanupOperation(id: operationID)
                == nil
        )
    }

    @Test
    func postCommitMaintenanceFailureIsJournaledAndRetryable()
        async throws
    {
        let database = try WalletDatabase.temporary()
        try await seedWallet(in: database)
        let operationID = UUID()
        _ = try await database.commitAppReset(
            cleanupPlan: .empty,
            operationID: operationID
        )

        let failed = await database.performPostResetMaintenance(
            operationID: operationID
        ) {
            throw SecureCleanupTestError.injected
        }
        #expect(!failed)
        #expect(try await walletCount(in: database) == 0)
        let failedOperation = try #require(
            try await database.secureCleanupOperation(id: operationID)
        )
        #expect(
            failedOperation.maintenanceState
                == WalletSecureCleanupMaintenanceState.failed.rawValue
        )
        #expect(failedOperation.maintenanceErrorCode != nil)

        let completed = await database.performPostResetMaintenance(
            operationID: operationID
        ) {}
        #expect(completed)
        let completedOperation = try #require(
            try await database.secureCleanupOperation(id: operationID)
        )
        #expect(
            completedOperation.maintenanceState
                == WalletSecureCleanupMaintenanceState.complete.rawValue
        )
        #expect(completedOperation.maintenanceErrorCode == nil)
    }

    @Test
    func failedSecretDeletionRemainsPendingUntilRetrySucceeds()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let operationID = UUID()
        _ = try await database.commitAppReset(
            cleanupPlan: WalletAppResetCleanupPlan(
                secretReferences: ["opaque-wallet-secret"],
                requiresPushCleanup: false
            ),
            operationID: operationID
        )
        let vault = FaultInjectingSecureCleanupVault(
            references: ["opaque-wallet-secret"],
            failingReferences: ["opaque-wallet-secret"]
        )

        let first = await database.retryPendingSecretCleanup(vault: vault)
        #expect(first.completedCount == 0)
        #expect(first.pendingCount == 1)
        let failedJob = try #require(
            try await database.pendingSecureCleanupJobs(
                operationID: operationID
            ).first
        )
        #expect(failedJob.attemptCount == 1)
        #expect(failedJob.lastErrorCode != nil)

        vault.setFailingReferences([])
        let retry = await database.retryPendingSecretCleanup(vault: vault)
        #expect(retry.completedCount == 1)
        #expect(retry.pendingCount == 0)
        #expect(
            try await database.pendingSecureCleanupJobs(
                operationID: operationID
            ).isEmpty
        )
        let operation = try #require(
            try await database.secureCleanupOperation(id: operationID)
        )
        #expect(
            operation.cleanupState
                == WalletSecureCleanupState.complete.rawValue
        )
        #expect(vault.references().isEmpty)
    }

    @Test
    @MainActor
    func walletRemovalCommitsDespiteKeychainFailureAndRetries()
        async throws
    {
        let database = try WalletDatabase.temporary()
        try await seedWallet(in: database)
        let plan = try await database.prepareWalletRemoval(
            walletID: "cleanup-wallet"
        )
        let backupDataKeyReference = WalletBackupDataKeyStore.reference(
            walletID: "cleanup-wallet"
        )
        let vault = FaultInjectingSecureCleanupVault(
            references: [
                "opaque-wallet-secret",
                "opaque-bitcoin-hd-keys",
                "opaque-passcode",
                backupDataKeyReference
            ],
            failingReferences: [
                "opaque-wallet-secret",
                "opaque-bitcoin-hd-keys",
                "opaque-passcode",
                backupDataKeyReference
            ]
        )

        var progressStages: [WalletRemovalProgressStage] = []
        let result = try await database.executeWalletRemoval(
            plan,
            vault: vault,
            onProgress: { stage in
                progressStages.append(stage)
            }
        )
        #expect(progressStages == WalletRemovalProgressStage.allCases)
        #expect(
            progressStages.map(\.ordinal)
                == Array(1...progressStages.count)
        )
        #expect(
            progressStages.allSatisfy {
                $0.total == progressStages.count
            }
        )
        #expect(!result.hasWallets)
        #expect(try await walletCount(in: database) == 0)
        let operation = try #require(
            try await latestRemovalOperation(in: database)
        )
        let operationID = try #require(UUID(uuidString: operation.id))
        let failedJobs = try await database.pendingSecureCleanupJobs(
            operationID: operationID
        )
        #expect(failedJobs.count == 4)
        #expect(failedJobs.allSatisfy { $0.attemptCount == 1 })

        vault.setFailingReferences([])
        let retry = await database.retryPendingSecretCleanup(vault: vault)
        #expect(retry.completedCount == 4)
        #expect(retry.pendingCount == 0)
        #expect(vault.references().isEmpty)
    }

    @Test
    func staleWalletRemovalPlanCannotDeleteChangedWallet()
        async throws
    {
        let database = try WalletDatabase.temporary()
        try await seedWallet(in: database)
        let plan = try await database.prepareWalletRemoval(
            walletID: "cleanup-wallet"
        )
        _ = try await database.renameWallet(
            walletID: "cleanup-wallet",
            name: "Changed Wallet"
        )

        do {
            _ = try await database.executeWalletRemoval(
                plan,
                vault: FaultInjectingSecureCleanupVault(
                    references: ["opaque-wallet-secret"]
                )
            )
            Issue.record("A stale removal plan unexpectedly committed.")
        } catch WalletManagementError.removalPlanStale {
            // Expected: the record is re-read inside the write transaction.
        } catch {
            Issue.record("Unexpected removal error: \(type(of: error))")
        }

        #expect(try await walletCount(in: database) == 1)
        #expect(try await removalOperationCount(in: database) == 0)
    }

    private func seedWallet(in database: WalletDatabase) async throws {
        let now = Date().timeIntervalSince1970
        try await database.pool.write { db in
            try DBWalletRecord(
                id: "cleanup-wallet",
                profileID: WalletDatabase.defaultProfileID,
                name: "Cleanup Wallet",
                kind: DatabaseWalletKind.created.rawValue,
                secretKeyReference: "opaque-wallet-secret",
                isSelected: true,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: now,
                archivedAt: nil
            ).insert(db)
            try DBWalletAccountRecord(
                id: "cleanup-account",
                walletID: "cleanup-wallet",
                networkID: "eth",
                address:
                    "0x1111111111111111111111111111111111111111",
                normalizedAddress:
                    "0x1111111111111111111111111111111111111111",
                label: nil,
                derivationPath: "m/44'/60'/0'/0/0",
                accountIndex: 0,
                publicKey: nil,
                isWatchOnly: false,
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil
            ).insert(db)
            try DBProfileSecurityRecord(
                profileID: WalletDatabase.defaultProfileID,
                passcodeKeychainReference: "opaque-passcode",
                failedAttemptCount: 0,
                lockedUntil: nil,
                updatedAt: now
            ).insert(db)
            try DBBitcoinHDKeyCacheRecord(
                walletID: "cleanup-wallet",
                addressType: BitcoinHDAddressType.bip84.rawValue,
                branch: BitcoinHDAddressBranch.external.rawValue,
                keychainReference: "opaque-bitcoin-hd-keys",
                highestCachedIndex: 19,
                createdAt: now,
                updatedAt: now
            ).insert(db)
        }
    }

    private func walletCount(in database: WalletDatabase) async throws
        -> Int
    {
        try await database.pool.read { db in
            try DBWalletRecord.fetchCount(db)
        }
    }

    private func latestRemovalOperation(
        in database: WalletDatabase
    ) async throws -> DBSecureCleanupOperationRecord? {
        try await database.pool.read { db in
            try DBSecureCleanupOperationRecord
                .filter(
                    Column("scope")
                        == WalletSecureCleanupScope.walletRemoval.rawValue
                )
                .order(Column("committedAt").desc)
                .fetchOne(db)
        }
    }

    private func removalOperationCount(
        in database: WalletDatabase
    ) async throws -> Int {
        try await database.pool.read { db in
            try DBSecureCleanupOperationRecord
                .filter(
                    Column("scope")
                        == WalletSecureCleanupScope.walletRemoval.rawValue
                )
                .fetchCount(db)
        }
    }
}

private enum SecureCleanupTestError: Error {
    case injected
}

private final class FaultInjectingSecureCleanupVault:
    WalletSecureCleanupVault, @unchecked Sendable
{
    private let lock = NSLock()
    private var storedReferences: Set<String>
    private var failingReferences: Set<String>

    init(
        references: Set<String>,
        failingReferences: Set<String> = []
    ) {
        storedReferences = references
        self.failingReferences = failingReferences
    }

    func allReferences() throws -> [String] {
        lock.withLock { storedReferences.sorted() }
    }

    func deleteIfPresent(reference: String) throws {
        try delete(reference: reference)
    }

    func deletePasscodeCredential(reference: String) throws {
        try delete(reference: reference)
    }

    func setFailingReferences(_ references: Set<String>) {
        lock.withLock {
            failingReferences = references
        }
    }

    func references() -> Set<String> {
        lock.withLock { storedReferences }
    }

    private func delete(reference: String) throws {
        try lock.withLock {
            if failingReferences.contains(reference) {
                throw SecureCleanupTestError.injected
            }
            storedReferences.remove(reference)
        }
    }
}

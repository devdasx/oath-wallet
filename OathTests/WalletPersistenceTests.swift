import Foundation
import GRDB
import Security
import Testing
@testable import Aperture

struct WalletPersistenceTests {
    @Test
    func createdWalletSecretsStayInKeychainAndOutOfDatabaseRows() async throws {
        let database = try WalletDatabase.temporary()
        let draft = try WalletCoreService.generateEVMWallet()
        let identity = try await database.persistCreatedWallet(
            draft: draft, security: .reuseExistingProfile
        )
        let reference = try await storedSecretReference(walletID: identity.walletID, database: database)
        defer { try? WalletSecretVault.shared.deleteIfPresent(reference: reference) }
        let encodedSecret = try WalletSecretVault.shared.data(reference: reference)
        let credential = try WalletRecoveryCredential.decode(encodedSecret)
        // Compare without including credential values in a failed test's diagnostic.
        let vaultRoundTripMatches = credential.mnemonic == draft.mnemonic
        #expect(vaultRoundTripMatches)
        let needles = [draft.mnemonic, Data(draft.mnemonic.utf8).base64EncodedString(), encodedSecret.base64EncodedString()]
        let databaseContainsSecret = try await database.pool.read { db in
            let tables = try String.fetchAll(db, sql:
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
            )
            for table in tables {
                let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                for row in try Row.fetchAll(db, sql: "SELECT * FROM \(quoted)") {
                    for (_, value) in row {
                        switch value.storage {
                        case let .string(text):
                            if needles.contains(where: text.contains) { return true }
                        case let .blob(data):
                            if data.range(of: encodedSecret) != nil || data.range(of: Data(draft.mnemonic.utf8)) != nil { return true }
                        default: break
                        }
                    }
                }
            }
            return false
        }
        #expect(!databaseContainsSecret)
    }

    @Test
    func sendSkipsAuthenticationWhenAppLockIsDisabledAndCarriesProof()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let walletDraft = try WalletCoreService.generateEVMWallet()
        let identity = try await database.persistCreatedWallet(
            draft: walletDraft,
            security: .reuseExistingProfile
        )
        let secretReference = try await storedSecretReference(
            walletID: identity.walletID,
            database: database
        )
        defer {
            try? WalletSecretVault.shared.deleteIfPresent(
                reference: secretReference
            )
        }

        let sendDraft = sendAuthorizationDraft()
        let unprotectedRoute = try await SendAuthorizationRouter(
            database: database
        ).prepare(for: sendDraft)
        guard case .authorized = unprotectedRoute else {
            Issue.record(
                "An unprotected wallet must route directly to broadcast."
            )
            return
        }

        try await database.enableAppLock(passcode: "123456")
        let passcodeReference = try await database.pool.read { database in
            try DBProfileSecurityRecord.fetchOne(
                database,
                key: WalletDatabase.defaultProfileID
            )?.passcodeKeychainReference
        }
        defer {
            if let passcodeReference {
                try? WalletSecretVault.shared.deletePasscodeCredential(
                    reference: passcodeReference
                )
            }
        }

        let protectedRoute = try await SendAuthorizationRouter(
            database: database
        ).prepare(for: sendDraft)
        guard case .requiresPasscode = protectedRoute else {
            Issue.record(
                "A protected wallet must route through authentication."
            )
            return
        }
    }

    @Test
    func appLockCanBeEnabledWithoutAnExistingSecurityRecord()
        async throws
    {
        let database = try WalletDatabase.temporary()
        try await database.pool.write { database in
            guard var settings = try DBUserSettingsRecord.fetchOne(
                database,
                key: WalletDatabase.defaultProfileID
            ) else {
                throw WalletSecurityPersistenceError.missingSettings
            }
            settings.appLockEnabled = false
            settings.biometricEnabled = false
            settings.updatedAt = Date().timeIntervalSince1970
            try settings.update(database)
        }

        let securityBefore = try await database.pool.read { database in
            try DBProfileSecurityRecord.fetchOne(
                database,
                key: WalletDatabase.defaultProfileID
            )
        }
        #expect(securityBefore == nil)

        try await database.enableAppLock(passcode: "123456")

        let enabledState = try await database.pool.read { database in
            let settings = try DBUserSettingsRecord.fetchOne(
                database,
                key: WalletDatabase.defaultProfileID
            )
            let security = try DBProfileSecurityRecord.fetchOne(
                database,
                key: WalletDatabase.defaultProfileID
            )
            return (settings, security)
        }
        let passcodeReference =
            try #require(
                enabledState.1?.passcodeKeychainReference
            )
        defer {
            try? WalletSecretVault.shared.deletePasscodeCredential(
                reference: passcodeReference
            )
        }

        #expect(enabledState.0?.appLockEnabled == true)
        #expect(enabledState.0?.biometricEnabled == false)
        #expect(enabledState.1?.failedAttemptCount == 0)
        #expect(enabledState.1?.lockedUntil == nil)
        #expect(
            try await database.authenticatePasscode("123456")
                == .success
        )
    }

    @Test
    func createdWalletPersistsOnTransferredUnprotectedProfile()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let draft = try WalletCoreService.generateEVMWallet()

        let securityBefore = try await database.pool.read { database in
            try DBProfileSecurityRecord.fetchOne(
                database,
                key: WalletDatabase.defaultProfileID
            )
        }
        #expect(securityBefore == nil)

        let identity = try await database.persistCreatedWallet(
            draft: draft,
            security: .reuseExistingProfile
        )
        let secretReference = try await storedSecretReference(
            walletID: identity.walletID,
            database: database
        )
        defer {
            try? WalletSecretVault.shared.deleteIfPresent(
                reference: secretReference
            )
        }

        let snapshot = try await persistenceSnapshot(
            walletID: identity.walletID,
            database: database
        )
        #expect(snapshot.walletKind == DatabaseWalletKind.created.rawValue)
        #expect(snapshot.accountCount > 0)
        #expect(snapshot.profileSecurityCount == 0)
        #expect(!snapshot.appLockEnabled)
        #expect(!snapshot.biometricEnabled)
    }

    @Test
    func recoveryPhraseImportPersistsOnTransferredUnprotectedProfile()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let phrase = WalletCredentialTestFixtures.recoveryPhrase()
        let passphrase = "import-passphrase"
        let draft = try WalletCoreService.importRecoveryPhrase(
            phrase,
            passphrase: passphrase
        )

        let identity = try await database.persistImportedWallet(
            draft: draft,
            security: .reuseExistingProfile
        )
        let secretReference = try await storedSecretReference(
            walletID: identity.walletID,
            database: database
        )
        defer {
            try? WalletSecretVault.shared.deleteIfPresent(
                reference: secretReference
            )
        }
        let credential = try WalletRecoveryCredential.decode(
            WalletSecretVault.shared.data(reference: secretReference)
        )
        #expect(credential.passphrase == passphrase)

        let snapshot = try await persistenceSnapshot(
            walletID: identity.walletID,
            database: database
        )
        #expect(
            snapshot.walletKind
                == DatabaseWalletKind.importedRecoveryPhrase.rawValue
        )
        #expect(snapshot.accountCount > 0)
        #expect(snapshot.profileSecurityCount == 0)
        #expect(!snapshot.appLockEnabled)
        #expect(!snapshot.biometricEnabled)
    }

    @Test
    func persistenceFailuresPreserveActionableCauses() {
        let missingSecurity = WalletPersistenceFailure(
            error: WalletCreationPersistenceError.missingSecret
        )
        #expect(
            missingSecurity.messageKey
                == "wallet.persistence.error.missing_security"
        )
        #expect(
            missingSecurity.diagnosticCode
                == "required_security_record_missing"
        )

        let entitlement = WalletPersistenceFailure(
            error: WalletSecretVaultError.unexpectedStatus(
                errSecMissingEntitlement
            )
        )
        #expect(
            entitlement.messageKey
                == "wallet.persistence.error.secure_storage_entitlement"
        )
        #expect(
            entitlement.diagnosticCode
                == "keychain_missing_entitlement_\(errSecMissingEntitlement)"
        )

        let databaseBusy = WalletPersistenceFailure(
            error: DatabaseError(resultCode: .SQLITE_BUSY)
        )
        #expect(
            databaseBusy.messageKey
                == "wallet.persistence.error.database_busy"
        )
        #expect(databaseBusy.diagnosticCode == "sqlite_busy_5")
    }

    @Test
    func transactionNotesPersistIntoTransactionDetailsAndCanBeRemoved()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let transactionID = "note-transaction"
        try await insertTransactionFixture(
            id: transactionID,
            database: database
        )
        let store = WalletDataStore(database: database)

        try await store.setTransactionNote(
            transactionID: transactionID,
            note: "  Rent for July\nPaid in full  "
        )

        #expect(
            try await store.transactionNote(
                transactionID: transactionID
            ) == "Rent for July\nPaid in full"
        )
        let snapshot = try await database.cachedWalletSnapshot(
            walletID: "note-wallet"
        )
        #expect(
            snapshot?.transactions.first?.metadata.note
                == "Rent for July\nPaid in full"
        )

        try await store.setTransactionNote(
            transactionID: transactionID,
            note: "Updated rent note"
        )
        #expect(
            try await store.transactionNote(
                transactionID: transactionID
            ) == "Updated rent note"
        )
        let updatedSnapshot = try await database.cachedWalletSnapshot(
            walletID: "note-wallet"
        )
        #expect(
            updatedSnapshot?.transactions.first?.metadata.note
                == "Updated rent note"
        )
        let noteRecordCount = try await database.pool.read { database in
            try DBTransactionNoteRecord.fetchCount(database)
        }
        #expect(noteRecordCount == 1)

        try await database.pool.write { database in
            guard var refreshedTransaction = try DBTransactionRecord.fetchOne(
                database,
                key: transactionID
            ) else {
                throw WalletDataStoreError.missingRecord
            }
            refreshedTransaction.displayTime = "Refreshed"
            refreshedTransaction.updatedAt += 1
            try refreshedTransaction.save(database)
        }
        #expect(
            try await store.transactionNote(
                transactionID: transactionID
            ) == "Updated rent note"
        )

        try await store.setTransactionNote(
            transactionID: transactionID,
            note: "   \n "
        )
        #expect(
            try await store.transactionNote(
                transactionID: transactionID
            ) == nil
        )
        let transactionStillExists = try await database.pool.read { database in
            try DBTransactionRecord.fetchOne(
                database,
                key: transactionID
            ) != nil
        }
        #expect(transactionStillExists)
    }

    @Test
    func transactionNoteFailuresPreserveActionableCauses() {
        #expect(
            WalletTransactionNoteFailure.messageKey(
                for: WalletDataStoreError.missingRecord
            ) == "wallet.transaction.details.notes.error.missing"
        )
        #expect(
            WalletTransactionNoteFailure.messageKey(
                for: DatabaseError(resultCode: .SQLITE_BUSY)
            ) == "wallet.transaction.details.notes.error.database_busy"
        )
        #expect(
            WalletTransactionNoteFailure.messageKey(
                for: DatabaseError(resultCode: .SQLITE_FULL)
            ) == "wallet.transaction.details.notes.error.storage_full"
        )
    }

    private func storedSecretReference(
        walletID: String,
        database: WalletDatabase
    ) async throws -> String {
        try await database.pool.read { database in
            guard let reference = try DBWalletRecord.fetchOne(
                database,
                key: walletID
            )?.secretKeyReference else {
                throw WalletCreationPersistenceError.missingSecret
            }
            return reference
        }
    }

    private func sendAuthorizationDraft() -> SendDraft {
        let asset = SendAssetChoice(
            id: "ethereum:native",
            name: "Ethereum",
            symbol: "ETH",
            networkID: "eth",
            networkName: "Ethereum",
            blockchain: .ethereum,
            contractAddress: nil,
            decimals: 18,
            logoSource: .nativeCoin(blockchain: .ethereum),
            networkLogoSource: .nativeCoin(blockchain: .ethereum),
            balance: 1,
            fiatValue: 0
        )
        return SendDraft(
            request: .manualEntry(networkID: "eth"),
            asset: asset,
            recipient:
                "0x0000000000000000000000000000000000000001",
            amount: "0.001",
            note: nil
        )
    }

    private func persistenceSnapshot(
        walletID: String,
        database: WalletDatabase
    ) async throws -> PersistenceSnapshot {
        try await database.pool.read { database in
            guard
                let wallet = try DBWalletRecord.fetchOne(
                    database,
                    key: walletID
                ),
                let settings = try DBUserSettingsRecord.fetchOne(
                    database,
                    key: WalletDatabase.defaultProfileID
                )
            else {
                throw WalletCreationPersistenceError.invalidDraft
            }

            return PersistenceSnapshot(
                walletKind: wallet.kind,
                accountCount: try DBWalletAccountRecord
                    .filter(Column("walletID") == walletID)
                    .fetchCount(database),
                profileSecurityCount:
                    try DBProfileSecurityRecord.fetchCount(database),
                appLockEnabled: settings.appLockEnabled,
                biometricEnabled: settings.biometricEnabled
            )
        }
    }

    private func insertTransactionFixture(
        id: String,
        database: WalletDatabase
    ) async throws {
        try await database.pool.write { db in
            let now = Date().timeIntervalSince1970
            try DBWalletRecord(
                id: "note-wallet",
                profileID: WalletDatabase.defaultProfileID,
                name: "Note Wallet",
                kind: DatabaseWalletKind.created.rawValue,
                secretKeyReference: nil,
                isSelected: false,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: nil,
                archivedAt: nil
            ).insert(db)
            try DBWalletAccountRecord(
                id: "note-account",
                walletID: "note-wallet",
                networkID: "eth",
                address:
                    "0x71C7656EC7ab88b098defB751B7401B5f6d8976F",
                normalizedAddress:
                    "0x71c7656ec7ab88b098defb751b7401b5f6d8976f",
                label: nil,
                derivationPath: nil,
                accountIndex: nil,
                publicKey: nil,
                isWatchOnly: false,
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil
            ).insert(db)
            try DBTransactionRecord(
                id: id,
                accountID: "note-account",
                networkID: "eth",
                transactionHash: "0xnote",
                normalizedTransactionHash: "0xnote",
                kind: "sent",
                status: "pending",
                direction: "outgoing",
                fromAddress: nil,
                toAddress:
                    "0x1111111111111111111111111111111111111111",
                counterpartyAddress:
                    "0x1111111111111111111111111111111111111111",
                blockNumber: nil,
                blockHash: nil,
                transactionIndex: nil,
                nonce: nil,
                transactionType: nil,
                timestamp: now,
                assetID: nil,
                assetSymbol: "ETH",
                secondaryAssetSymbol: nil,
                assetAmount: "1",
                fiatUSDValue: nil,
                networkFee: nil,
                networkFeeFiatUSDValue: nil,
                networkFeeSymbol: nil,
                gasPriceGwei: nil,
                gasLimit: nil,
                gasUsed: nil,
                inputData: nil,
                methodName: nil,
                displayDetail:
                    "0x1111111111111111111111111111111111111111",
                displayTime: "",
                firstSeenAt: now,
                updatedAt: now
            ).insert(db)
        }
    }
}

private struct PersistenceSnapshot: Sendable {
    let walletKind: String
    let accountCount: Int
    let profileSecurityCount: Int
    let appLockEnabled: Bool
    let biometricEnabled: Bool
}

@Suite(.serialized)
struct TronSnapshotPersistenceTests {
    private static let walletOne = "tron-wallet-one"
    private static let walletTwo = "tron-wallet-two"
    private static let addressOne =
        "TQn9Y2khEsLJW1ChVWFMSMeRDow5KcbLSE"
    private static let addressTwo =
        "TPYmHEhy5n8TCEfYGqW2rPxsghSfzghPDn"
    private static let usdtContract =
        "TXLAQ63Xg1NAzckPwKHvzw7CSEmLMEqcdj"
    private static let usdcContract =
        "TEkxiTehnzSmSe2XqrBj4w32RUN966rdz8"

    @Test
    func omittedTokenIsZeroedWhileReturnedTokenAndPreferencesPersist()
        async throws
    {
        let database = try WalletDatabase.temporary()
        try await seedWallet(
            walletID: Self.walletOne,
            address: Self.addressOne,
            database: database
        )
        try await seedToken(
            contract: Self.usdtContract,
            symbol: "USDT",
            database: database
        )
        try await seedToken(
            contract: Self.usdcContract,
            symbol: "USDC",
            database: database
        )
        try await seedHolding(
            walletID: Self.walletOne,
            contract: Self.usdtContract,
            balance: "7.5",
            atomicBalance: "7500000",
            fiatValue: "7.5",
            database: database
        )
        try await seedHolding(
            walletID: Self.walletOne,
            contract: Self.usdcContract,
            balance: "3",
            atomicBalance: "3000000",
            fiatValue: "3",
            isEnabled: false,
            isPinned: true,
            isHidden: true,
            sortOrder: 42,
            database: database
        )

        let snapshot = snapshot(
            walletID: Self.walletOne,
            address: Self.addressOne,
            tokens: [
                TronTokenBalance(
                    identity: Self.usdtContract,
                    type: "trc20",
                    name: "Tether USD",
                    symbol: "USDT",
                    decimals: 6,
                    amountText: "2",
                    rawAmount: "2000000"
                )
            ],
            queriedTRC20Identities: [
                Self.usdtContract,
                Self.usdcContract
            ]
        )
        try await database.saveTronSnapshot(
            snapshot,
            walletID: Self.walletOne,
            resolvedPrices: ["tron:\(Self.usdtContract)": 1]
        )

        let result = try await database.pool.read { database in
            let accountID = "\(Self.walletOne):tron:0"
            return (
                returned: try DBAccountAssetRecord.fetchOne(
                    database,
                    key: [
                        "accountID": accountID,
                        "assetID": "tron:\(Self.usdtContract)"
                    ]
                ),
                omitted: try DBAccountAssetRecord.fetchOne(
                    database,
                    key: [
                        "accountID": accountID,
                        "assetID": "tron:\(Self.usdcContract)"
                    ]
                ),
                omittedAsset: try DBAssetRecord.fetchOne(
                    database,
                    key: "tron:\(Self.usdcContract)"
                ),
                account: try DBWalletAccountRecord.fetchOne(
                    database,
                    key: accountID
                )
            )
        }
        let returned = try #require(result.returned)
        let omitted = try #require(result.omitted)

        #expect(returned.balance == "2")
        #expect(returned.balanceAtomic == "2000000")
        #expect(returned.fiatUSDValue == "2")
        #expect(omitted.balance == "0")
        #expect(omitted.balanceAtomic == "0")
        #expect(omitted.fiatUSDValue == "0")
        #expect(!omitted.isEnabled)
        #expect(omitted.isPinned)
        #expect(omitted.isHidden)
        #expect(omitted.sortOrder == 42)
        #expect(result.omittedAsset != nil)
        #expect(result.account?.lastSyncedAt != nil)
    }

    @Test
    func reconciliationNeverChangesAnotherWallet() async throws {
        let database = try WalletDatabase.temporary()
        try await seedWallet(
            walletID: Self.walletOne,
            address: Self.addressOne,
            database: database
        )
        try await seedWallet(
            walletID: Self.walletTwo,
            address: Self.addressTwo,
            database: database
        )
        try await seedToken(
            contract: Self.usdtContract,
            symbol: "USDT",
            database: database
        )
        for walletID in [Self.walletOne, Self.walletTwo] {
            try await seedHolding(
                walletID: walletID,
                contract: Self.usdtContract,
                balance: walletID == Self.walletOne ? "4" : "9",
                atomicBalance: walletID == Self.walletOne
                    ? "4000000" : "9000000",
                fiatValue: walletID == Self.walletOne ? "4" : "9",
                database: database
            )
        }

        try await database.saveTronSnapshot(
            snapshot(
                walletID: Self.walletOne,
                address: Self.addressOne,
                tokens: [],
                queriedTRC20Identities: [Self.usdtContract]
            ),
            walletID: Self.walletOne,
            resolvedPrices: [:]
        )

        let holdings = try await database.pool.read { database in
            try [
                "\(Self.walletOne):tron:0",
                "\(Self.walletTwo):tron:0"
            ].map { accountID in
                try DBAccountAssetRecord.fetchOne(
                    database,
                    key: [
                        "accountID": accountID,
                        "assetID": "tron:\(Self.usdtContract)"
                    ]
                )
            }
        }
        let balances = try holdings.map { try #require($0).balance }
        #expect(balances == ["0", "9"])
    }

    @Test
    func incompleteTokenCoveragePreservesUnqueriedBalance()
        async throws
    {
        let database = try WalletDatabase.temporary()
        try await seedWallet(
            walletID: Self.walletOne,
            address: Self.addressOne,
            database: database
        )
        try await seedToken(
            contract: Self.usdtContract,
            symbol: "USDT",
            database: database
        )
        try await seedHolding(
            walletID: Self.walletOne,
            contract: Self.usdtContract,
            balance: "11",
            atomicBalance: "11000000",
            fiatValue: "11",
            database: database
        )

        try await database.saveTronSnapshot(
            snapshot(
                walletID: Self.walletOne,
                address: Self.addressOne,
                tokens: [],
                queriedTRC20Identities: []
            ),
            walletID: Self.walletOne,
            resolvedPrices: [:]
        )

        let state = try await database.pool.read { database in
            let accountID = "\(Self.walletOne):tron:0"
            return (
                holding: try DBAccountAssetRecord.fetchOne(
                    database,
                    key: [
                        "accountID": accountID,
                        "assetID": "tron:\(Self.usdtContract)"
                    ]
                ),
                account: try DBWalletAccountRecord.fetchOne(
                    database,
                    key: accountID
                )
            )
        }
        #expect(state.holding?.balance == "11")
        #expect(state.holding?.balanceAtomic == "11000000")
        #expect(state.holding?.fiatUSDValue == "11")
        #expect(state.account?.lastSyncedAt != nil)
    }

    @Test
    func pinnedTRC20TokensRemainInTheNextBalanceQueryInventory()
        async throws
    {
        let database = try WalletDatabase.temporary()
        try await seedWallet(
            walletID: Self.walletOne,
            address: Self.addressOne,
            database: database
        )
        try await seedToken(
            contract: Self.usdtContract,
            symbol: "USDT",
            database: database
        )
        try await seedHolding(
            walletID: Self.walletOne,
            contract: Self.usdtContract,
            balance: "1",
            atomicBalance: "1000000",
            fiatValue: "1",
            isPinned: true,
            database: database
        )
        try await seedToken(
            contract: "1002000",
            symbol: "TRC10",
            database: database
        )
        try await seedHolding(
            walletID: Self.walletOne,
            contract: "1002000",
            balance: "2",
            atomicBalance: "2",
            fiatValue: nil,
            database: database
        )

        let tracked = try await database.trackedTronTokens(
            walletID: Self.walletOne
        )
        let byIdentity = Dictionary(
            uniqueKeysWithValues: tracked.map { ($0.identity, $0) }
        )

        #expect(byIdentity[Self.usdtContract]?.type == "trc20")
        #expect(byIdentity[Self.usdtContract]?.decimals == 6)
        #expect(byIdentity["1002000"] == nil)
    }

    @Test
    func incompleteOrErroredRPCBatchIsRejected() {
        #expect(throws: AnkrAPIError.self) {
            try TronAPIClient.validatedBatchResponses(
                [
                    TronRPCResponse(
                        id: 1,
                        result: "0x0",
                        error: nil
                    )
                ],
                expectedIDs: [1, 2]
            )
        }
        #expect(throws: TronRPCError.self) {
            try TronAPIClient.validatedBatchResponses(
                [
                    TronRPCResponse(
                        id: 1,
                        result: nil,
                        error: TronRPCError(
                            code: -32_000,
                            message: "test provider failure"
                        )
                    )
                ],
                expectedIDs: [1]
            )
        }
    }

    @Test
    func failedProviderSnapshotNeverInvokesPersistence() async {
        let probe = TronSnapshotSaveProbe()
        let service = TronSyncService(
            accountLoader: { _ in
                TronAccountMaterial(
                    address: Self.addressOne,
                    hexAddress:
                        "0x1111111111111111111111111111111111111111",
                    publicKey: "test-public-key"
                )
            },
            trackedTokenLoader: { _ in [] },
            snapshotLoader: { _, _ in
                throw URLError(.timedOut)
            },
            snapshotSaver: { _, _ in
                await probe.recordSave()
            }
        )

        let outcome = await service.sync(walletID: Self.walletOne)

        #expect(!outcome.didPersistData)
        #expect(outcome.failures.count == 1)
        #expect(
            outcome.failures.first?.publicCode
                == "transport_error_-1001"
        )
        #expect(await probe.saveCount() == 0)
    }

    private func snapshot(
        walletID: String,
        address: String,
        tokens: [TronTokenBalance],
        queriedTRC20Identities: Set<String>
    ) -> TronWalletSnapshot {
        TronWalletSnapshot(
            material: TronAccountMaterial(
                address: address,
                hexAddress:
                    "0x1111111111111111111111111111111111111111",
                publicKey: "test-public-key-\(walletID)"
            ),
            trxBalance: 0,
            tokens: tokens,
            history: [],
            queriedTRC20Identities: queriedTRC20Identities
        )
    }

    private func seedWallet(
        walletID: String,
        address: String,
        database: WalletDatabase
    ) async throws {
        try await database.pool.write { database in
            let now = Date().timeIntervalSince1970
            try DBWalletRecord(
                id: walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: walletID,
                kind: DatabaseWalletKind.created.rawValue,
                secretKeyReference: nil,
                isSelected: false,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: nil,
                archivedAt: nil
            ).insert(database)
            try DBWalletAccountRecord(
                id: "\(walletID):tron:0",
                walletID: walletID,
                networkID: TronConstants.networkID,
                address: address,
                normalizedAddress: address,
                label: nil,
                derivationPath: nil,
                accountIndex: 0,
                publicKey: "test-public-key",
                isWatchOnly: false,
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil
            ).insert(database)
        }
    }

    private func seedToken(
        contract: String,
        symbol: String,
        database: WalletDatabase
    ) async throws {
        try await database.pool.write { database in
            let now = Date().timeIntervalSince1970
            try DBAssetRecord(
                id: "tron:\(contract)",
                networkID: TronConstants.networkID,
                assetType: DatabaseAssetType.fungibleToken.rawValue,
                contractAddress: contract,
                normalizedContractAddress: contract,
                name: symbol,
                symbol: symbol,
                decimals: contract == "1002000" ? 0 : 6,
                trustWalletBlockchain: WalletBlockchain.tron.rawValue,
                trustWalletContractAddress: contract,
                isVerified: true,
                isSpam: false,
                createdAt: now,
                updatedAt: now,
                metadataUpdatedAt: now
            ).save(database)
        }
    }

    private func seedHolding(
        walletID: String,
        contract: String,
        balance: String,
        atomicBalance: String,
        fiatValue: String?,
        isEnabled: Bool = true,
        isPinned: Bool = false,
        isHidden: Bool = false,
        sortOrder: Int = 1,
        database: WalletDatabase
    ) async throws {
        try await database.pool.write { database in
            let now = Date().timeIntervalSince1970
            try DBAccountAssetRecord(
                accountID: "\(walletID):tron:0",
                assetID: "tron:\(contract)",
                balance: balance,
                balanceAtomic: atomicBalance,
                fiatUSDValue: fiatValue,
                isEnabled: isEnabled,
                isPinned: isPinned,
                isHidden: isHidden,
                sortOrder: sortOrder,
                firstSeenAt: now - 100,
                lastSeenAt: now - 50,
                updatedAt: now - 50
            ).save(database)
        }
    }
}

private actor TronSnapshotSaveProbe {
    private var count = 0

    func recordSave() {
        count += 1
    }

    func saveCount() -> Int {
        count
    }
}

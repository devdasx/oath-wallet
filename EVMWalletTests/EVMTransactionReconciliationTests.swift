import Foundation
import GRDB
import Testing
@testable import Aperture

@Suite(.serialized)
struct EVMTransactionReconciliationTests {
    @Test
    func confirmedProviderSnapshotReusesPendingLocalSubmission()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let fixture = try await seedFixture(database: database)
        try await insertLocalSubmission(
            fixture: fixture,
            status: "pending",
            note: "Keep this note",
            database: database
        )

        let transaction = providerTransaction(
            fixture: fixture,
            providerID: "provider-native",
            amount: "-1.25",
            status: .confirmed,
            blockNumber: 123
        )
        let providerID = WalletDatabase.transactionRecordID(
            transaction,
            walletAddress: fixture.walletAddress,
            networkID: fixture.networkID
        )
        try await synchronize(
            transaction,
            fixture: fixture,
            database: database
        )

        let result = try await reconciliationSnapshot(
            fixture: fixture,
            providerID: providerID,
            database: database
        )
        #expect(result.transactions.count == 1)
        #expect(result.transactions.first?.id == fixture.localID)
        #expect(result.transactions.first?.status == "confirmed")
        #expect(result.transactions.first?.blockNumber == 123)
        #expect(result.note?.note == "Keep this note")
        #expect(result.transfer?.amountAtomic == fixture.amountAtomic)
        #expect(result.providerRow == nil)
    }

    @Test
    func confirmedLocalSubmissionRemainsCanonicalAcrossRepeatedSync()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let fixture = try await seedFixture(database: database)
        try await insertLocalSubmission(
            fixture: fixture,
            status: "confirmed",
            note: "Local metadata",
            database: database
        )
        let transaction = providerTransaction(
            fixture: fixture,
            providerID: "provider-native",
            amount: "-1.25",
            status: .confirmed,
            blockNumber: 456
        )

        try await synchronize(
            transaction,
            fixture: fixture,
            database: database
        )
        try await synchronize(
            transaction,
            fixture: fixture,
            database: database
        )

        let result = try await reconciliationSnapshot(
            fixture: fixture,
            database: database
        )
        #expect(result.transactions.count == 1)
        #expect(result.transactions.first?.id == fixture.localID)
        #expect(result.transactions.first?.blockNumber == 456)
        #expect(result.note?.note == "Local metadata")
        #expect(result.transfer?.amountAtomic == fixture.amountAtomic)
    }

    @Test
    func highPrecisionProviderAmountReconcilesUsingExactText()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let fixture = try await seedFixture(database: database)
        try await insertLocalSubmission(
            fixture: fixture,
            status: "pending",
            note: "Exact amount",
            database: database
        )
        let exactMagnitude =
            "115792089237316195423570985008687907853269984665640564039457.584007913129639935"
        let atomic = AnkrTokenAmount.maximumUInt256
        let updateCounts = try await database.pool.write { database in
            let transactionCount = try DBTransactionRecord
                .filter(Column("id") == fixture.localID)
                .updateAll(
                    database,
                    Column("assetAmount").set(to: exactMagnitude)
                )
            let transferCount = try DBTransactionTransferRecord
                .filter(
                    Column("id") == "\(fixture.localID)|primary"
                )
                .updateAll(
                    database,
                    Column("amount").set(to: exactMagnitude),
                    Column("amountAtomic").set(to: atomic)
                )
            return (transactionCount, transferCount)
        }
        #expect(updateCounts.0 == 1)
        #expect(updateCounts.1 == 1)

        let transaction = providerTransaction(
            fixture: fixture,
            providerID: "provider-high-precision",
            amount: "-1",
            assetAmountText: "-\(exactMagnitude)",
            assetAmountAtomic: atomic,
            status: .confirmed,
            blockNumber: 457
        )
        try await synchronize(
            transaction,
            fixture: fixture,
            database: database
        )

        let result = try await reconciliationSnapshot(
            fixture: fixture,
            database: database
        )
        #expect(result.transactions.count == 1)
        #expect(result.transactions.first?.id == fixture.localID)
        #expect(
            result.transactions.first?.assetAmount
                == "-\(exactMagnitude)"
        )
        #expect(result.note?.note == "Exact amount")
        #expect(result.transfer?.amount == "-\(exactMagnitude)")
        #expect(result.transfer?.amountAtomic == atomic)
    }

    @Test
    func existingProviderDuplicateMergesMetadataIntoLocalSubmission()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let fixture = try await seedFixture(database: database)
        try await insertLocalSubmission(
            fixture: fixture,
            status: "confirmed",
            note: "User note",
            database: database
        )
        let transaction = providerTransaction(
            fixture: fixture,
            providerID: "provider-native",
            amount: "-1.25",
            status: .confirmed,
            blockNumber: 789
        )
        let providerID = WalletDatabase.transactionRecordID(
            transaction,
            walletAddress: fixture.walletAddress,
            networkID: fixture.networkID
        )
        try await insertProviderDuplicateMetadata(
            providerID: providerID,
            fixture: fixture,
            database: database
        )

        try await synchronize(
            transaction,
            fixture: fixture,
            database: database
        )

        let result = try await reconciliationSnapshot(
            fixture: fixture,
            providerID: providerID,
            database: database
        )
        #expect(result.transactions.count == 1)
        #expect(result.transactions.first?.id == fixture.localID)
        #expect(result.note?.note == "User note")
        #expect(result.providerRow == nil)
        #expect(result.tagTransactionID == fixture.localID)
        #expect(result.notificationTransactionID == fixture.localID)
    }

    @Test
    func historicalRepairCollapsesPersistedProviderDuplicate()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let fixture = try await seedFixture(database: database)
        try await insertLocalSubmission(
            fixture: fixture,
            status: "pending",
            note: "Historical user note",
            database: database
        )
        let transaction = providerTransaction(
            fixture: fixture,
            providerID: "historical-provider-native",
            amount: "-1.25",
            status: .confirmed,
            blockNumber: 789
        )
        let providerID = WalletDatabase.transactionRecordID(
            transaction,
            walletAddress: fixture.walletAddress,
            networkID: fixture.networkID
        )
        try await insertProviderDuplicateMetadata(
            providerID: providerID,
            fixture: fixture,
            database: database
        )

        try await database.pool.write { database in
            try WalletDatabase.repairHistoricalEVMTransactionDuplicates(
                database: database
            )
        }

        let result = try await reconciliationSnapshot(
            fixture: fixture,
            providerID: providerID,
            database: database
        )
        #expect(result.transactions.count == 1)
        #expect(result.transactions.first?.id == fixture.localID)
        #expect(result.transactions.first?.status == "confirmed")
        #expect(result.transactions.first?.blockNumber == 789)
        #expect(result.note?.note == "Historical user note")
        #expect(result.transfer?.amountAtomic == fixture.amountAtomic)
        #expect(result.providerRow == nil)
        #expect(result.tagTransactionID == fixture.localID)
        #expect(result.notificationTransactionID == fixture.localID)
    }

    @Test
    func distinctSameHashProviderEventIsNotCollapsed()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let fixture = try await seedFixture(database: database)
        try await insertLocalSubmission(
            fixture: fixture,
            status: "pending",
            note: nil,
            database: database
        )
        try await synchronize(
            providerTransaction(
                fixture: fixture,
                providerID: "provider-event-zero",
                amount: "-1.25",
                status: .confirmed,
                blockNumber: 111,
                logIndex: 0
            ),
            fixture: fixture,
            database: database
        )
        let distinctEvent = providerTransaction(
            fixture: fixture,
            providerID: "provider-event-one",
            amount: "-2.50",
            status: .confirmed,
            blockNumber: 111,
            logIndex: 1
        )
        try await synchronize(
            distinctEvent,
            fixture: fixture,
            database: database
        )
        let distinctProviderID = WalletDatabase.transactionRecordID(
            distinctEvent,
            walletAddress: fixture.walletAddress,
            networkID: fixture.networkID
        )

        let records = try await database.pool.read { database in
            try DBTransactionRecord
                .filter(Column("accountID") == fixture.accountID)
                .filter(Column("networkID") == fixture.networkID)
                .filter(
                    Column("normalizedTransactionHash")
                        == fixture.transactionHash
                )
                .filter(Column("assetID") == fixture.assetID)
                .order(Column("id"))
                .fetchAll(database)
        }
        #expect(records.count == 2)
        #expect(records.contains { $0.id == fixture.localID })
        #expect(records.contains { $0.id == distinctProviderID })
    }

    @Test
    func migrationInstallsLocalIdentityInvariantAndLookupIndex()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let fixture = try await seedFixture(database: database)
        try await insertLocalSubmission(
            fixture: fixture,
            status: "pending",
            note: nil,
            database: database
        )

        let indexes = try await database.pool.read { database in
            try String.fetchAll(
                database,
                sql: """
                SELECT name
                FROM sqlite_master
                WHERE type = 'index'
                    AND name IN (
                        'transactions_evm_reconciliation_lookup',
                        'transactions_local_send_identity'
                    )
                ORDER BY name
                """
            )
        }
        #expect(
            indexes == [
                "transactions_evm_reconciliation_lookup",
                "transactions_local_send_identity"
            ]
        )

        var rejectedDuplicate = false
        do {
            try await database.pool.write { database in
                var duplicate = localRecord(
                    fixture: fixture,
                    status: "pending"
                )
                duplicate = DBTransactionRecord(
                    id: "\(fixture.localID):duplicate",
                    accountID: duplicate.accountID,
                    networkID: duplicate.networkID,
                    transactionHash: duplicate.transactionHash,
                    normalizedTransactionHash:
                        duplicate.normalizedTransactionHash,
                    kind: duplicate.kind,
                    status: duplicate.status,
                    direction: duplicate.direction,
                    fromAddress: duplicate.fromAddress,
                    toAddress: duplicate.toAddress,
                    counterpartyAddress: duplicate.counterpartyAddress,
                    blockNumber: duplicate.blockNumber,
                    blockHash: duplicate.blockHash,
                    transactionIndex: duplicate.transactionIndex,
                    nonce: duplicate.nonce,
                    transactionType: duplicate.transactionType,
                    timestamp: duplicate.timestamp,
                    assetID: duplicate.assetID,
                    assetSymbol: duplicate.assetSymbol,
                    secondaryAssetSymbol: duplicate.secondaryAssetSymbol,
                    assetAmount: duplicate.assetAmount,
                    fiatUSDValue: duplicate.fiatUSDValue,
                    networkFee: duplicate.networkFee,
                    networkFeeFiatUSDValue:
                        duplicate.networkFeeFiatUSDValue,
                    networkFeeSymbol: duplicate.networkFeeSymbol,
                    gasPriceGwei: duplicate.gasPriceGwei,
                    gasLimit: duplicate.gasLimit,
                    gasUsed: duplicate.gasUsed,
                    inputData: duplicate.inputData,
                    methodName: duplicate.methodName,
                    displayDetail: duplicate.displayDetail,
                    displayTime: duplicate.displayTime,
                    firstSeenAt: duplicate.firstSeenAt,
                    updatedAt: duplicate.updatedAt
                )
                try duplicate.insert(database)
            }
        } catch {
            rejectedDuplicate = true
        }
        #expect(rejectedDuplicate)
    }

    private func seedFixture(
        database: WalletDatabase
    ) async throws -> Fixture {
        let fixture = Fixture()
        try await database.pool.write { database in
            let now = fixture.now
            try DBWalletRecord(
                id: fixture.walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Reconciliation Wallet",
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
                id: fixture.accountID,
                walletID: fixture.walletID,
                networkID: fixture.networkID,
                address: fixture.walletAddress,
                normalizedAddress: fixture.walletAddress,
                label: nil,
                derivationPath: "m/44'/60'/0'/0/0",
                accountIndex: 0,
                publicKey: nil,
                isWatchOnly: false,
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil
            ).insert(database)
            try DBAssetRecord(
                id: fixture.assetID,
                networkID: fixture.networkID,
                assetType: DatabaseAssetType.native.rawValue,
                contractAddress: "",
                normalizedContractAddress: "",
                name: "Ether",
                symbol: "ETH",
                decimals: 18,
                trustWalletBlockchain: WalletBlockchain.ethereum.rawValue,
                trustWalletContractAddress: nil,
                isVerified: true,
                isSpam: false,
                createdAt: now,
                updatedAt: now,
                metadataUpdatedAt: now
            ).insert(database)
        }
        return fixture
    }

    private func insertLocalSubmission(
        fixture: Fixture,
        status: String,
        note: String?,
        database: WalletDatabase
    ) async throws {
        try await database.pool.write { database in
            try localRecord(
                fixture: fixture,
                status: status
            ).insert(database)
            try DBTransactionTransferRecord(
                id: "\(fixture.localID)|primary",
                transactionID: fixture.localID,
                logIndex: nil,
                assetID: fixture.assetID,
                fromAddress: fixture.walletAddress,
                toAddress: fixture.recipientAddress,
                direction: "outgoing",
                amount: fixture.amount,
                amountAtomic: fixture.amountAtomic,
                fiatUSDValue: nil,
                tokenName: "Ether",
                tokenSymbol: "ETH",
                tokenDecimals: 18
            ).insert(database)
            if let note {
                try DBTransactionNoteRecord(
                    transactionID: fixture.localID,
                    note: note,
                    createdAt: fixture.now,
                    updatedAt: fixture.now
                ).insert(database)
            }
        }
    }

    private func insertProviderDuplicateMetadata(
        providerID: String,
        fixture: Fixture,
        database: WalletDatabase
    ) async throws {
        try await database.pool.write { database in
            let provider = providerRecord(
                id: providerID,
                fixture: fixture,
                amount: "-1.25"
            )
            try provider.insert(database)
            try DBTransactionTransferRecord(
                id: "\(providerID)|primary",
                transactionID: providerID,
                logIndex: nil,
                assetID: fixture.assetID,
                fromAddress: fixture.walletAddress,
                toAddress: fixture.recipientAddress,
                direction: "outgoing",
                amount: "-1.25",
                amountAtomic: nil,
                fiatUSDValue: "-3000",
                tokenName: "Ether",
                tokenSymbol: "ETH",
                tokenDecimals: 18
            ).insert(database)
            try DBTransactionNoteRecord(
                transactionID: providerID,
                note: "Provider note",
                createdAt: fixture.now,
                updatedAt: fixture.now
            ).insert(database)
            try DBTagRecord(
                id: fixture.tagID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Provider Tag",
                createdAt: fixture.now
            ).insert(database)
            try DBTransactionTagRecord(
                transactionID: providerID,
                tagID: fixture.tagID
            ).insert(database)
            try DBNotificationRecord(
                id: fixture.notificationID,
                profileID: WalletDatabase.defaultProfileID,
                category: "transfer",
                titleKey: "notification.generic.title",
                bodyKey: "notification.generic.body",
                argumentsJSON: nil,
                relatedTransactionID: providerID,
                createdAt: fixture.now,
                readAt: nil,
                deliveredAt: fixture.now
            ).insert(database)
        }
    }

    private func synchronize(
        _ transaction: WalletTransaction,
        fixture: Fixture,
        database: WalletDatabase
    ) async throws {
        try await database.pool.write { database in
            let fetchedAsset = try DBAssetRecord.fetchOne(
                database,
                key: fixture.assetID
            )
            var assets = [
                fixture.assetID:
                    try #require(fetchedAsset)
            ]
            let providerID = WalletDatabase.transactionRecordID(
                transaction,
                walletAddress: fixture.walletAddress,
                networkID: fixture.networkID
            )
            var existing: [String: DBTransactionRecord] = [:]
            if let providerRecord = try DBTransactionRecord.fetchOne(
                database,
                key: providerID
            ) {
                existing[providerID] = providerRecord
            }
            let fetchedAccount = try DBWalletAccountRecord.fetchOne(
                database,
                key: fixture.accountID
            )
            try WalletDatabase.upsertTransaction(
                transaction,
                walletAddress: fixture.walletAddress,
                accountsByNetwork: [
                    fixture.networkID:
                        try #require(fetchedAccount)
                ],
                persistedAssetsByID: &assets,
                existingTransactionsByID: &existing,
                now: fixture.now + 10,
                database: database
            )
        }
    }

    private func reconciliationSnapshot(
        fixture: Fixture,
        providerID: String? = nil,
        database: WalletDatabase
    ) async throws -> ReconciliationSnapshot {
        try await database.pool.read { database in
            let transactions = try DBTransactionRecord
                .filter(Column("accountID") == fixture.accountID)
                .filter(Column("networkID") == fixture.networkID)
                .filter(
                    Column("normalizedTransactionHash")
                        == fixture.transactionHash
                )
                .filter(Column("assetID") == fixture.assetID)
                .order(Column("id"))
                .fetchAll(database)
            return ReconciliationSnapshot(
                transactions: transactions,
                note: try DBTransactionNoteRecord.fetchOne(
                    database,
                    key: fixture.localID
                ),
                transfer: try DBTransactionTransferRecord.fetchOne(
                    database,
                    key: "\(fixture.localID)|primary"
                ),
                providerRow: try providerID.flatMap {
                    try DBTransactionRecord.fetchOne(database, key: $0)
                },
                tagTransactionID: try DBTransactionTagRecord
                    .filter(Column("tagID") == fixture.tagID)
                    .fetchOne(database)?
                    .transactionID,
                notificationTransactionID:
                    try DBNotificationRecord.fetchOne(
                        database,
                        key: fixture.notificationID
                    )?.relatedTransactionID
            )
        }
    }

    private func localRecord(
        fixture: Fixture,
        status: String
    ) -> DBTransactionRecord {
        DBTransactionRecord(
            id: fixture.localID,
            accountID: fixture.accountID,
            networkID: fixture.networkID,
            transactionHash: fixture.transactionHash,
            normalizedTransactionHash: fixture.transactionHash,
            kind: "sent",
            status: status,
            direction: "outgoing",
            fromAddress: fixture.walletAddress,
            toAddress: fixture.recipientAddress,
            counterpartyAddress: fixture.recipientAddress,
            blockNumber: status == "confirmed" ? 100 : nil,
            blockHash: nil,
            transactionIndex: nil,
            nonce: 7,
            transactionType: 2,
            timestamp: fixture.now,
            assetID: fixture.assetID,
            assetSymbol: "ETH",
            secondaryAssetSymbol: nil,
            assetAmount: fixture.amount,
            fiatUSDValue: nil,
            networkFee: "0.00021",
            networkFeeFiatUSDValue: nil,
            networkFeeSymbol: "ETH",
            gasPriceGwei: "10",
            gasLimit: 21_000,
            gasUsed: nil,
            inputData: "0x",
            methodName: nil,
            displayDetail: fixture.recipientAddress,
            displayTime: "Pending",
            firstSeenAt: fixture.now,
            updatedAt: fixture.now
        )
    }

    private func providerRecord(
        id: String,
        fixture: Fixture,
        amount: String
    ) -> DBTransactionRecord {
        DBTransactionRecord(
            id: id,
            accountID: fixture.accountID,
            networkID: fixture.networkID,
            transactionHash: fixture.transactionHash,
            normalizedTransactionHash: fixture.transactionHash,
            kind: "sent",
            status: "confirmed",
            direction: "outgoing",
            fromAddress: fixture.walletAddress,
            toAddress: fixture.recipientAddress,
            counterpartyAddress: fixture.recipientAddress,
            blockNumber: 789,
            blockHash: "0xblock",
            transactionIndex: 1,
            nonce: 7,
            transactionType: 2,
            timestamp: fixture.now + 5,
            assetID: fixture.assetID,
            assetSymbol: "ETH",
            secondaryAssetSymbol: nil,
            assetAmount: amount,
            fiatUSDValue: "-3000",
            networkFee: "0.00021",
            networkFeeFiatUSDValue: "-0.50",
            networkFeeSymbol: "ETH",
            gasPriceGwei: "10",
            gasLimit: 21_000,
            gasUsed: 21_000,
            inputData: "0x",
            methodName: nil,
            displayDetail: fixture.recipientAddress,
            displayTime: "Confirmed",
            firstSeenAt: fixture.now + 5,
            updatedAt: fixture.now + 5
        )
    }

    private func providerTransaction(
        fixture: Fixture,
        providerID: String,
        amount: String,
        assetAmountText: String? = nil,
        assetAmountAtomic: String? = nil,
        status: WalletTransactionStatus,
        blockNumber: Int64,
        logIndex: Int? = nil
    ) -> WalletTransaction {
        WalletTransaction(
            id: providerID,
            kind: .sent(assetSymbol: "ETH"),
            detail: fixture.recipientAddress,
            time: "Confirmed",
            assetLogoSource: .nativeCoin(blockchain: .ethereum),
            assetAmount:
                Decimal(
                    string: amount,
                    locale: Locale(identifier: "en_US_POSIX")
                ) ?? 0,
            assetAmountText: assetAmountText,
            assetAmountAtomic: assetAmountAtomic,
            assetSymbol: "ETH",
            fiatValue: -3000,
            status: status,
            metadata: WalletTransactionMetadata(
                transactionHash: fixture.transactionHash,
                blockchainIdentifier: fixture.networkID,
                date: Date(timeIntervalSince1970: fixture.now + 5),
                fromAddress: fixture.walletAddress,
                toAddress: fixture.recipientAddress,
                blockNumber: blockNumber,
                blockHash: "0xblock",
                contractAddress: nil,
                tokenName: "Ether",
                tokenDecimals: 18,
                logIndex: logIndex,
                networkFee: Decimal(string: "0.00021"),
                networkFeeFiatValue: Decimal(string: "0.50"),
                networkFeeSymbol: "ETH",
                gasPriceGwei: 10,
                gasLimit: 21_000,
                gasUsed: 21_000,
                nonce: 7,
                transactionIndex: 1,
                transactionType: 2,
                inputData: "0x",
                note: nil
            )
        )
    }
}

private struct Fixture {
    let walletID = "evm-reconciliation-wallet"
    let accountID = "evm-reconciliation-account"
    let networkID = "eth"
    let assetID = "eth:native"
    let walletAddress =
        "0x71c7656ec7ab88b098defb751b7401b5f6d8976f"
    let recipientAddress =
        "0x1111111111111111111111111111111111111111"
    let transactionHash =
        "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    let amount = "1.25"
    let amountAtomic = "1250000000000000000"
    let now = 1_750_000_000.0
    let tagID = "evm-reconciliation-tag"
    let notificationID = "evm-reconciliation-notification"

    var localID: String {
        [
            "send",
            accountID,
            networkID,
            transactionHash,
            assetID
        ].joined(separator: ":")
    }
}

private struct ReconciliationSnapshot {
    let transactions: [DBTransactionRecord]
    let note: DBTransactionNoteRecord?
    let transfer: DBTransactionTransferRecord?
    let providerRow: DBTransactionRecord?
    let tagTransactionID: String?
    let notificationTransactionID: String?
}

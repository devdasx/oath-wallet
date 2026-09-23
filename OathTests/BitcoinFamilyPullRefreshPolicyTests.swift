import Foundation
import GRDB
import Testing
@testable import Aperture

struct BitcoinFamilyPullRefreshPolicyTests {
    @Test
    func knownOutputRefreshUsesPublicScriptsWithoutScanKeysOrCheckpointAdvancement() async throws {
        let fixture = try await Self.silentPaymentFixture()
        let before = try #require(try await fixture.database.bitcoinSilentPaymentAccount(walletID: fixture.walletID))
        let client = KnownOutputPublicDataFixture(transactionHash: fixture.transactionHash, omitHistory: false)
        let result = try await BitcoinSilentPaymentSyncService(database: fixture.database, electrum: client)
            .refresh(walletID: fixture.walletID)
        #expect(result.balanceAtomic.decimalText == "1000")
        #expect(!result.balanceIsAuthoritative)
        let after = try #require(try await fixture.database.bitcoinSilentPaymentAccount(walletID: fixture.walletID))
        #expect(after.lastScanHeight == before.lastScanHeight)
        // Fixture Keychain references do not exist: this also proves no scan-key read.
        let calls = await client.calls
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.hasPrefix("blockchain.scripthash.") })
    }

    @Test
    func missingPublicHistoryPreservesKnownFundsWhenNoLocalScanExists() async throws {
        let fixture = try await Self.silentPaymentFixture()
        let client = KnownOutputPublicDataFixture(transactionHash: fixture.transactionHash, omitHistory: true)
        await #expect(throws: BitcoinSilentPaymentSyncError.invalidElectrumResponse) {
            _ = try await BitcoinSilentPaymentSyncService(database: fixture.database, electrum: client)
                .refresh(walletID: fixture.walletID)
        }
        let outputs = try await fixture.database.bitcoinSilentPaymentOutputs(walletID: fixture.walletID)
        #expect(outputs.count == 1)
        #expect(outputs.first?.isSpent == false)
    }

    private static let silentPaymentAddress =
        "sp1qqgste7k9hx0qftg6qmwlkqtwuy6cycyavzmzj85c6qdfhjdpdjtdgqjuex"
        + "zk6murw56suy3e0rd2cgqvycxttddwsvgxe2usfpxumr70xc9pkqwv"

    @Test @MainActor
    func homeRefreshBoundaryCannotAwaitProviderCompletion() {
        requireSynchronousRefreshAction(\WalletHomeView.onRefresh)
        requireSynchronousRefreshAction(
            \WalletHomePortfolioView.onRefresh
        )
    }

    @Test
    func benchmarkedFastestMainnetEndpointsArePrimary() {
        #expect(BitcoinFamilyChain.bitcoin.endpoints.first?.0 == "blockstream.info")
        #expect(BitcoinFamilyChain.bitcoinCash.endpoints.first?.0 == "bch.loping.net")
        #expect(BitcoinFamilyChain.litecoin.endpoints.first?.0 == "electrum1.cipig.net")
        #expect(BitcoinFamilyChain.dogecoin.endpoints.first?.0 == "electrum1.cipig.net")
    }

    @Test
    func coldSnapshotPrefersElectrumBeforeIndexedFallbacks() {
        #expect(
            BitcoinFamilySyncService.snapshotProviderBaselineOrder == [
                .electrum,
                .blockchair,
                .blockCypher
            ]
        )
    }

    @Test
    func coldSnapshotFallbackChainHasOneBoundedBudget() {
        #expect(
            BitcoinFamilySyncService.snapshotOverallTimeoutSeconds
                < BitcoinFamilySyncService.snapshotAttemptTimeoutSeconds
                    * Double(
                        BitcoinFamilySyncService
                            .snapshotProviderBaselineOrder.count
                    )
        )
        #expect(
            BitcoinFamilySyncService.snapshotOverallTimeoutSeconds >= 12
        )
    }

    @Test
    func activeFullWalletLoadGetsIndependentBitcoinBalanceRefresh() {
        #expect(
            BitcoinFamilyPullRefreshPolicy
                .requiresIndependentBalanceRefresh(
                    hasActiveWalletLoad: true,
                    sources: [.evm, .bitcoinFamily, .solana]
                )
        )
    }

    @Test
    func idleWalletUsesNormalSynchronization() {
        #expect(
            !BitcoinFamilyPullRefreshPolicy
                .requiresIndependentBalanceRefresh(
                    hasActiveWalletLoad: false,
                    sources: [.bitcoinFamily]
                )
        )
    }

    @Test
    func privateKeyWalletWithoutBitcoinSkipsFastLane() {
        #expect(
            !BitcoinFamilyPullRefreshPolicy
                .requiresIndependentBalanceRefresh(
                    hasActiveWalletLoad: true,
                    sources: [.evm]
                )
        )
    }

    @Test(arguments: BitcoinHDAddressType.allCases)
    func removedMempoolPaymentAcceptsZeroWithEmptyHistory(
        _ addressType: BitcoinHDAddressType
    ) throws {
        let state = Self.hdState(
            addressType: addressType,
            balanceAtomic: 1_000
        )
        var transactions = Set<BitcoinHDTransactionReference>()
        let result = try BitcoinHDDiscoveryService.parse(
                states: [state],
                histories: [
                    BitcoinFamilyElectrumBatchValue(
                        parameter: state.derived.scriptHash,
                        value: .array([])
                    )
                ],
                balances: [
                    BitcoinFamilyElectrumBatchValue(
                        parameter: state.derived.scriptHash,
                        value: .object([
                            "confirmed": .string("0"),
                            "unconfirmed": .string("0"),
                        ])
                    )
                ],
                transactions: &transactions
            )
        #expect(result.first?.balanceAtomic == .zero)
        #expect(result.first?.isUsed == true)
        #expect(transactions.isEmpty)
    }

    @Test
    func fundedHDAddressAcceptsGenuineSpentZeroWithHistory() throws {
        let state = Self.hdState(
            addressType: .bip84,
            balanceAtomic: 1_000
        )
        let transactionHash = String(repeating: "ab", count: 32)
        var transactions = Set<BitcoinHDTransactionReference>()
        let result = try BitcoinHDDiscoveryService.parse(
            states: [state],
            histories: [
                BitcoinFamilyElectrumBatchValue(
                    parameter: state.derived.scriptHash,
                    value: .array([
                        .object([
                            "tx_hash": .string(transactionHash),
                            "height": .string("800000"),
                        ])
                    ])
                )
            ],
            balances: [
                BitcoinFamilyElectrumBatchValue(
                    parameter: state.derived.scriptHash,
                    value: .object([
                        "confirmed": .string("0"),
                        "unconfirmed": .string("0"),
                    ])
                )
            ],
            transactions: &transactions
        )
        #expect(result.first?.balanceAtomic == .zero)
        #expect(transactions.map(\.transactionHash) == [transactionHash])
    }

    @Test
    func removedFirstPaymentAcceptsZeroWithoutHistory() throws {
        let funded = try BitcoinFamilyAtomicInteger(validating: "1000")

        try BitcoinFamilySyncService.validateBalanceTransition(
            previousBalance: funded, fetchedBalance: .zero, hasHistoryEvidence: false)
        try BitcoinFamilySyncService.validateZeroBalanceHistoryEvidence(.array([]))
    }

    @Test
    func fundedSingleAddressAcceptsGenuineSpentZeroWithHistory() throws {
        let funded = try BitcoinFamilyAtomicInteger(validating: "1000")
        let transactionHash = String(repeating: "ab", count: 32)
        let history = JSONValue.array([
            .object([
                "tx_hash": .string(transactionHash),
                "height": .string("800000"),
            ])
        ])

        try BitcoinFamilySyncService.validateZeroBalanceHistoryEvidence(
            history
        )
        try BitcoinFamilySyncService.validateBalanceTransition(
            previousBalance: funded,
            fetchedBalance: .zero,
            hasHistoryEvidence: true
        )
    }

    @Test
    func malformedElectrumHistoryCannotAuthorizeZeroBalance() {
        let malformed = JSONValue.array([
            .object([
                "tx_hash": .string("not-a-transaction-hash"),
                "height": .string("800000"),
            ])
        ])

        #expect(throws: BitcoinFamilyElectrumError.self) {
            try BitcoinFamilySyncService.validateZeroBalanceHistoryEvidence(
                malformed
            )
        }
    }

    @Test
    func silentPaymentScanCoverageNeverGuessesAboutOlderOutputs() {
        #expect(
            BitcoinSilentPaymentSyncService.scanAuthoritativelyCovers(
                blockHeight: 800_050,
                startHeight: 800_000,
                tipHeight: 800_100
            )
        )
        #expect(
            !BitcoinSilentPaymentSyncService.scanAuthoritativelyCovers(
                blockHeight: 799_999,
                startHeight: 800_000,
                tipHeight: 800_100
            )
        )
        #expect(
            !BitcoinSilentPaymentSyncService.scanAuthoritativelyCovers(
                blockHeight: nil,
                startHeight: 800_000,
                tipHeight: 800_100
            )
        )
    }

    @Test
    func incompleteSilentPaymentScanCannotBlockStandardBalancePublication()
        async throws
    {
        let fixture = try await Self.silentPaymentFixture()
        let standardState = Self.hdState(
            addressType: .bip84,
            balanceAtomic: 125_000_000
        )
        let cachedSilentState = try await fixture.database
            .bitcoinSilentPaymentCachedState(walletID: fixture.walletID)
        let silentResult = BitcoinSilentPaymentWalletResult(
            outputs: cachedSilentState.outputs,
            balanceAtomic: cachedSilentState.outputs
                .filter { !$0.isSpent }
                .reduce(.zero) { $0.adding($1.valueAtomic) },
            transactions: [],
            balanceIsAuthoritative:
                cachedSilentState.balanceIsAuthoritative
        )

        let result = try await BitcoinHDWalletSyncService(
            database: fixture.database
        ).publishKnownBalance(
            standardResult: BitcoinHDDiscoveryResult(
                states: [standardState],
                balanceAtomic: standardState.balanceAtomic,
                transactions: [],
                receiveAddress: standardState.derived
            ),
            silentResult: silentResult,
            walletID: fixture.walletID
        )

        #expect(result.balanceAtomic.decimalText == "125001000")
        #expect(
            try await fixture.database.bitcoinFamilyPersistedBalance(
                walletID: fixture.walletID
            )?.decimalText == "125001000"
        )
    }

    @Test
    func silentPaymentReconciliationRollsBackAsOneUnit() async throws {
        let fixture = try await Self.silentPaymentFixture()
        let database = fixture.database
        let walletID = fixture.walletID
        let hash = fixture.transactionHash

        let initial = try await database.bitcoinSilentPaymentCachedState(
            walletID: walletID
        )
        #expect(!initial.balanceIsAuthoritative)
        #expect(initial.outputs.first?.isSpent == false)

        await #expect(throws: BitcoinSilentPaymentDatabaseError.invalidOutput) {
            try await database.completeBitcoinSilentPaymentReconciliation(
                walletID: walletID,
                scanHeight: 800_100,
                mutations: [
                    .markOrphaned(
                        transactionHash: hash,
                        outputIndex: 0
                    ),
                    .markOrphaned(
                        transactionHash: String(repeating: "cd", count: 32),
                        outputIndex: 1
                    ),
                ]
            )
        }

        let rolledBack = try await database.bitcoinSilentPaymentCachedState(
            walletID: walletID
        )
        #expect(!rolledBack.balanceIsAuthoritative)
        #expect(rolledBack.outputs.first?.isSpent == false)

        try await database.completeBitcoinSilentPaymentReconciliation(
            walletID: walletID,
            scanHeight: 800_100,
            mutations: [
                .markSpent(
                    transactionHash: hash,
                    outputIndex: 0,
                    spendingTransactionHash:
                        String(repeating: "ef", count: 32)
                )
            ]
        )
        let completed = try await database.bitcoinSilentPaymentCachedState(
            walletID: walletID
        )
        #expect(!completed.balanceIsAuthoritative)
        #expect(completed.outputs.first?.isSpent == true)
    }

    @Test
    func silentPaymentScanCheckpointSurvivesDatabaseRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let walletID = UUID().uuidString.lowercased()
        let activation = WalletDatabase.bitcoinSilentPaymentActivationHeight
        let checkpointHeight = activation + 24_999
        let targetHeight = activation + 50_000
        let now = Date().timeIntervalSince1970

        do {
            let database = try WalletDatabase.applicationDatabase(
                at: directory
            )
            let address = try BitcoinSilentPaymentAddress(
                Self.silentPaymentAddress
            )
            try await database.pool.write { rawDatabase in
                try DBWalletRecord(
                    id: walletID,
                    profileID: WalletDatabase.defaultProfileID,
                    name: "Silent Payment Relaunch Test",
                    kind: DatabaseWalletKind.importedRecoveryPhrase.rawValue,
                    secretKeyReference: nil,
                    isSelected: true,
                    sortOrder: 0,
                    createdAt: now,
                    updatedAt: now,
                    lastOpenedAt: now,
                    archivedAt: nil
                ).insert(rawDatabase)
                try DBBitcoinSilentPaymentAccountRecord(
                    walletID: walletID,
                    address: address.encoded,
                    scanPublicKey: address.scanPublicKey,
                    spendPublicKey: address.spendPublicKey,
                    keychainReference: "relaunch-test-account-reference",
                    birthHeight: activation,
                    lastScanHeight: activation - 1,
                    balanceIsAuthoritative: false,
                    createdAt: now,
                    updatedAt: now
                ).insert(rawDatabase)
            }

            try await database.beginBitcoinSilentPaymentScan(
                walletID: walletID,
                targetHeight: targetHeight
            )
            try await database.completeBitcoinSilentPaymentReconciliation(
                walletID: walletID,
                scanHeight: checkpointHeight,
                mutations: [],
                balanceIsAuthoritative: false
            )
        }

        let reopened = try WalletDatabase.applicationDatabase(at: directory)
        let partial = try #require(
            try await reopened.pool.read { rawDatabase in
                try DBBitcoinSilentPaymentAccountRecord.fetchOne(
                    rawDatabase,
                    key: walletID
                ).flatMap(BitcoinSilentPaymentScanProgress.init)
            }
        )
        #expect(partial.lastScanHeight == checkpointHeight)
        #expect(partial.targetHeight == targetHeight)
        #expect(partial.isScanning)
        #expect(try #require(partial.completionFraction) > 0)
        #expect(try #require(partial.completionFraction) < 1)

        try await reopened.completeBitcoinSilentPaymentReconciliation(
            walletID: walletID,
            scanHeight: targetHeight,
            mutations: [],
            balanceIsAuthoritative: true
        )
        let completed = try #require(
            try await reopened.pool.read { rawDatabase in
                try DBBitcoinSilentPaymentAccountRecord.fetchOne(
                    rawDatabase,
                    key: walletID
                ).flatMap(BitcoinSilentPaymentScanProgress.init)
            }
        )
        #expect(!completed.isScanning)
        #expect(completed.completionFraction == 1)
        #expect(
            try await !reopened.bitcoinSilentPaymentCachedState(
                walletID: walletID
            ).balanceIsAuthoritative
        )
    }

    private static func hdState(
        addressType: BitcoinHDAddressType,
        balanceAtomic: Int64
    ) -> BitcoinHDAddressState {
        BitcoinHDAddressState(
            derived: BitcoinHDDerivedAddress(
                addressType: addressType,
                branch: .external,
                index: 0,
                derivationPath: "m/\(addressType.purposeNumber)'/0'/0'/0/0",
                address: "test-\(addressType.rawValue)",
                publicKey: Data(repeating: 2, count: 33),
                scriptPubKey: Data([0x00, 0x14])
                    + Data(repeating: 3, count: 20),
                scriptHash: "hash-\(addressType.rawValue)"
            ),
            isUsed: true,
            isReserved: false,
            confirmedBalanceAtomic: BitcoinFamilyAtomicInteger(balanceAtomic),
            unconfirmedBalanceAtomic: .zero
        )
    }

    private static func silentPaymentFixture() async throws -> (
        database: WalletDatabase,
        walletID: String,
        transactionHash: String
    ) {
        let database = try WalletDatabase.temporary()
        let walletID = UUID().uuidString.lowercased()
        let transactionHash = String(repeating: "ab", count: 32)
        let address = try BitcoinSilentPaymentAddress(silentPaymentAddress)
        let outputKey = Data(repeating: 7, count: 32)
        let now = Date().timeIntervalSince1970
        let accountID =
            "\(walletID):\(BitcoinFamilyChain.bitcoin.networkID):0"
        let assetID = "\(BitcoinFamilyChain.bitcoin.networkID):native"
        try await database.pool.write { rawDatabase in
            try DBWalletRecord(
                id: walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Balance Authority Test",
                kind: DatabaseWalletKind.importedRecoveryPhrase.rawValue,
                secretKeyReference: nil,
                isSelected: true,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: now,
                archivedAt: nil
            ).insert(rawDatabase)
            try DBWalletAccountRecord(
                id: accountID,
                walletID: walletID,
                networkID: BitcoinFamilyChain.bitcoin.networkID,
                address: "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu",
                normalizedAddress:
                    "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu",
                label: nil,
                derivationPath: "m/84'/0'/0'/0/0",
                accountIndex: 0,
                publicKey: String(repeating: "02", count: 33),
                isWatchOnly: false,
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil
            ).insert(rawDatabase)
            try DBAssetRecord(
                id: assetID,
                networkID: BitcoinFamilyChain.bitcoin.networkID,
                assetType: DatabaseAssetType.native.rawValue,
                contractAddress: "",
                normalizedContractAddress: "",
                name: BitcoinFamilyChain.bitcoin.name,
                symbol: BitcoinFamilyChain.bitcoin.symbol,
                decimals: 8,
                trustWalletBlockchain:
                    BitcoinFamilyChain.bitcoin.blockchain.rawValue,
                trustWalletContractAddress: nil,
                isVerified: true,
                isSpam: false,
                createdAt: now,
                updatedAt: now,
                metadataUpdatedAt: now
            ).insert(rawDatabase)
            try DBAccountAssetRecord(
                accountID: accountID,
                assetID: assetID,
                balance: "0",
                balanceAtomic: "0",
                fiatUSDValue: "0",
                isEnabled: true,
                isPinned: false,
                isHidden: false,
                sortOrder: 0,
                firstSeenAt: now,
                lastSeenAt: now,
                updatedAt: now
            ).insert(rawDatabase)
            try DBBitcoinSilentPaymentAccountRecord(
                walletID: walletID,
                address: address.encoded,
                scanPublicKey: address.scanPublicKey,
                spendPublicKey: address.spendPublicKey,
                keychainReference: "test-account-reference",
                birthHeight:
                    WalletDatabase.bitcoinSilentPaymentActivationHeight,
                lastScanHeight:
                    WalletDatabase.bitcoinSilentPaymentActivationHeight - 1,
                balanceIsAuthoritative: false,
                createdAt: now,
                updatedAt: now
            ).insert(rawDatabase)
            try DBBitcoinSilentPaymentOutputRecord(
                walletID: walletID,
                transactionHash: transactionHash,
                outputIndex: 0,
                valueAtomic: "1000",
                scriptPubKey: Data([0x51, 0x20]) + outputKey,
                outputPublicKey: outputKey,
                keychainReference: "test-output-reference",
                blockHeight: 800_000,
                blockTimestamp: nil,
                isSpent: false,
                spentByTransactionHash: nil,
                createdAt: now,
                updatedAt: now
            ).insert(rawDatabase)
        }
        return (database, walletID, transactionHash)
    }
}

private func requireSynchronousRefreshAction<Root>(
    _ keyPath: KeyPath<Root, () -> Void>
) {}


private actor KnownOutputPublicDataFixture: BitcoinSilentPaymentPublicDataClient {
    let transactionHash: String
    let omitHistory: Bool
    var calls: [String] = []
    init(transactionHash: String, omitHistory: Bool) {
        self.transactionHash = transactionHash
        self.omitHistory = omitHistory
    }
    func callStringParameterBatch(
        chain: BitcoinFamilyChain, method: String, parameters: [String], maximumResponseBytes: Int
    ) async throws -> [BitcoinFamilyElectrumBatchValue] {
        calls.append(method)
        let isHistory = method == "blockchain.scripthash.get_history"
        let entries: [[String: Any]] = isHistory && omitHistory ? [] : [
            ["tx_hash": transactionHash, "height": 800000, "tx_pos": 0, "value": 1000]
        ]
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: entries))
        return parameters.map { BitcoinFamilyElectrumBatchValue(parameter: $0, value: value) }
    }
    func silentPaymentRawTransaction(hash: String, maximumResponseBytes: Int) async throws -> JSONValue {
        Issue.record("Unexpected transaction fetch for an unspent output fixture")
        throw BitcoinSilentPaymentSyncError.invalidElectrumResponse
    }
}

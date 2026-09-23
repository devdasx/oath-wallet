import Foundation
import GRDB
import Testing
@testable import Aperture

@Suite(.serialized)
struct TronAssetEligibilityTests {
    private static let walletID = "tron-asset-eligibility-wallet"
    private static let walletAddress =
        "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7"
    private static let trc20Contract =
        "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"

    @Test
    func blanketCatalogContractsAreNotBalanceQueryCandidates() {
        let metadata = TronAPIClient.balanceQueryMetadata(
            trackedTokens: [],
            history: []
        )

        #expect(metadata.isEmpty)
    }

    @Test
    func onlyPinnedTRC20MetadataCanBypassHistoryDiscovery() {
        let metadata = TronAPIClient.balanceQueryMetadata(
            trackedTokens: [
                TronTrackedToken(
                    identity: Self.trc20Contract,
                    type: "trc20",
                    name: "Tether USD",
                    symbol: "USDT",
                    decimals: 6
                ),
                TronTrackedToken(
                    identity: "1002000",
                    type: "trc10",
                    name: "Legacy Token",
                    symbol: "OLD",
                    decimals: 6
                )
            ],
            history: []
        )

        #expect(Set(metadata.keys) == [Self.trc20Contract])
    }

    @Test
    func unsolicitedHistoryCannotBecomeABalanceQueryCandidate() {
        let deniedContract =
            "TVh4nokXoSxQGxh7T6Tn6NTb2uSUhAhLwb"
        let metadata = TronAPIClient.balanceQueryMetadata(
            trackedTokens: [],
            history: [
                Self.historyItem(
                    contract: deniedContract,
                    name: "fenergy.fun",
                    symbol: "fenergy.fun",
                    decimals: 6
                )
            ]
        )

        #expect(metadata[deniedContract] == nil)
    }

    @Test
    func safeProviderDiscoveredHistoryBecomesABalanceQueryCandidate() {
        let previous = ReceiveAssetCatalogRuntime.snapshot
        defer { ReceiveAssetCatalogRuntime.install(previous.tokens, revision: previous.revision) }
        ReceiveAssetCatalogRuntime.install([])
        let discoveredContract = Self.walletAddress
        let metadata = TronAPIClient.balanceQueryMetadata(
            trackedTokens: [],
            history: [
                Self.historyItem(
                    contract: discoveredContract,
                    name: "Example Token",
                    symbol: "EXAMPLE",
                    decimals: 6
                )
            ]
        )

        #expect(metadata[discoveredContract]?.name == "Example Token")
        #expect(metadata[discoveredContract]?.symbol == "EXAMPLE")
        #expect(metadata[discoveredContract]?.decimals == 6)
    }

    @Test
    func trustedCatalogHistoryUsesCatalogMetadata() {
        let previous = ReceiveAssetCatalogRuntime.snapshot
        defer {
            ReceiveAssetCatalogRuntime.install(
                previous.tokens,
                revision: previous.revision
            )
        }
        ReceiveAssetCatalogRuntime.install(
            [
                ReceiveToken(
                    id: "tron-usdt",
                    name: "Tether USD",
                    symbol: "USDT",
                    rank: 1,
                    isStablecoin: true,
                    variants: [
                        ReceiveTokenVariant(
                            networkID: TronConstants.networkID,
                            contractAddress: Self.trc20Contract,
                            decimals: 6,
                            networkRank: 1,
                            logoURL: nil,
                            marketDataID: "tether"
                        )
                    ]
                )
            ],
            revision: 1
        )
        let metadata = TronAPIClient.balanceQueryMetadata(
            trackedTokens: [],
            history: [
                Self.historyItem(
                    contract: Self.trc20Contract,
                    name: "Spoofed Name",
                    symbol: "SPOOF",
                    decimals: 6
                )
            ]
        )

        #expect(metadata[Self.trc20Contract]?.name == "Tether USD")
        #expect(metadata[Self.trc20Contract]?.symbol == "USDT")
    }

    @Test
    func trc10TransferContractsAreNotMappedAsNativeHistory() {
        let transaction = TronGridTransaction(
            txID: "trc10-transfer",
            blockNumber: 1,
            blockTimestamp: 1_725_000_000_000,
            ret: [
                TronGridTransaction.ReturnValue(
                    contractRet: "SUCCESS",
                    fee: 0
                )
            ],
            rawData: TronGridTransaction.RawData(
                contract: [
                    TronGridTransaction.RawData.Contract(
                        type: "TransferAssetContract",
                        parameter:
                            TronGridTransaction.RawData.Contract.Parameter(
                                value:
                                    TronGridTransaction.RawData.Contract
                                    .Parameter.Value(
                                        ownerAddress: Self.walletAddress,
                                        toAddress: Self.walletAddress,
                                        amount: 1,
                                        assetName: "31303032303030"
                                    )
                            )
                    )
                ]
            )
        )

        #expect(
            TronHistoryMapper.nativeTransfers(from: [transaction]).isEmpty
        )
    }

    private static func historyItem(
        contract: String,
        name: String,
        symbol: String,
        decimals: Int
    ) -> TronHistoryItem {
        TronHistoryItem(
            transactionID: UUID().uuidString,
            timestamp: 1,
            blockNumber: 1,
            from: walletAddress,
            to: walletAddress,
            amountText: "1",
            rawAmount: "1",
            assetIdentity: contract,
            assetSymbol: symbol,
            assetName: name,
            decimals: decimals,
            fee: nil,
            failed: false
        )
    }

    @Test
    func zeroBalanceSnapshotPersistsCatalogArtworkForOfflineReopening() async throws {
        let database = try WalletDatabase.temporary()
        try await seedWallet(database)
        let previous = ReceiveAssetCatalogRuntime.snapshot
        defer { ReceiveAssetCatalogRuntime.install(previous.tokens, revision: previous.revision) }
        let url = "oath-asset://catalog/stablecoin-usdt.png"
        ReceiveAssetCatalogRuntime.install([ReceiveToken(
            id: "fixture", name: "Tether", symbol: "USDT", rank: 1, isStablecoin: true,
            variants: [ReceiveTokenVariant(networkID: "tron", contractAddress: Self.trc20Contract,
                decimals: 6, networkRank: 1, logoURL: url)])])
        let snapshot = TronWalletSnapshot(
            material: TronAccountMaterial(address: Self.walletAddress,
                hexAddress: "410000000000000000000000000000000000000000", publicKey: "test"),
            trxBalance: 0,
            tokens: [TronTokenBalance(identity: Self.trc20Contract, type: "trc20",
                name: "USDT", symbol: "USDT", decimals: 6, amountText: "0", rawAmount: "0")],
            history: [], queriedTRC20Identities: [Self.trc20Contract])
        try await database.saveTronSnapshot(snapshot, walletID: Self.walletID, resolvedPrices: [:])
        ReceiveAssetCatalogRuntime.install([])
        // A subsequent balance refresh without a catalog must preserve the image too.
        try await database.saveTronSnapshot(snapshot, walletID: Self.walletID, resolvedPrices: [:])
        let record = try #require(try await database.pool.read { db in
            try DBAssetRecord.fetchOne(db, key: "tron:\(Self.trc20Contract)")
        })
        #expect(record.logoURL == url)
        #expect(record.logoOrigin == "catalog")
        #expect(WalletDatabase.logoSource(asset: record, fallbackNetwork: .tron)
            .remoteLogoURL?.absoluteString == url)
    }

    @Test
    func persistenceRejectsTRC10Balances() async throws {
        let database = try WalletDatabase.temporary()
        try await seedWallet(database)
        let snapshot = TronWalletSnapshot(
            material: TronAccountMaterial(
                address: Self.walletAddress,
                hexAddress:
                    "410000000000000000000000000000000000000000",
                publicKey: "test-public-key"
            ),
            trxBalance: 0,
            tokens: [
                TronTokenBalance(
                    identity: "1002000",
                    type: "trc10",
                    name: "Legacy Token",
                    symbol: "OLD",
                    decimals: 6,
                    amountText: "1",
                    rawAmount: "1000000"
                )
            ],
            history: [],
            queriedTRC20Identities: []
        )

        try await database.saveTronSnapshot(
            snapshot,
            walletID: Self.walletID,
            resolvedPrices: [:]
        )

        let stored = try await database.pool.read { database in
            (
                asset: try DBAssetRecord.fetchOne(
                    database,
                    key: "tron:1002000"
                ),
                holding: try DBAccountAssetRecord.fetchOne(
                    database,
                    key: [
                        "accountID": "\(Self.walletID):tron:0",
                        "assetID": "tron:1002000"
                    ]
                )
            )
        }
        #expect(stored.asset == nil)
        #expect(stored.holding == nil)
    }

    private func seedWallet(_ database: WalletDatabase) async throws {
        try await database.pool.write { database in
            let now = Date().timeIntervalSince1970
            try DBWalletRecord(
                id: Self.walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "TRON Eligibility Wallet",
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
                id: "\(Self.walletID):tron:0",
                walletID: Self.walletID,
                networkID: TronConstants.networkID,
                address: Self.walletAddress,
                normalizedAddress: Self.walletAddress,
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
}

import Foundation
import GRDB
import Testing
@testable import Aperture

struct RetiredEVMNetworksTests {
    private static let retiredNetworkIDs = Set(
        WalletDatabase.retiredEVMNetworkIDs
    )

    @Test
    func retiredNetworksAreAbsentFromEveryRuntimeCatalog() {
        let receiveNetworkIDs = Set(
            ReceiveNetworkCatalog.all.map(\.id)
        )
        let assetNetworkIDs = Set(
            ReceiveAssetCatalog.tokens.flatMap {
                $0.variants.map(\.networkID)
            }
        )

        #expect(receiveNetworkIDs.isDisjoint(with: Self.retiredNetworkIDs))
        #expect(assetNetworkIDs.isDisjoint(with: Self.retiredNetworkIDs))
        for networkID in Self.retiredNetworkIDs {
            #expect(
                !AnkrAPIClient.supportsTokenLookup(
                    networkID: networkID
                )
            )
        }
    }

    @Test
    func migrationRemovesRetiredNetworkHoldings() async throws {
        let database = try WalletDatabase.temporary()
        let now = Date().timeIntervalSince1970
        let walletID = "retired-networks-wallet"

        try await database.pool.write { db in
            try DBWalletRecord(
                id: walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Retirement Test Wallet",
                kind: DatabaseWalletKind.watchOnly.rawValue,
                secretKeyReference: nil,
                isSelected: false,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: nil,
                archivedAt: nil
            ).insert(db)

            for (
                index,
                networkID
            ) in WalletDatabase.retiredEVMNetworkIDs.enumerated() {
                let accountID = "\(walletID):\(networkID)"
                let assetID = "\(networkID):native"
                try DBNetworkRecord(
                    id: networkID,
                    chainID: Int64(
                        WalletDatabase.retiredEVMChainIDs[index]
                    ),
                    nameKey: "retired.network",
                    nativeSymbol: "OLD",
                    trustWalletBlockchain: networkID,
                    rpcProviderIdentifier: "retired-\(networkID)",
                    isMainnet: true,
                    isEnabled: true,
                    sortOrder: index,
                    createdAt: now,
                    updatedAt: now
                ).insert(db)
                try DBWalletAccountRecord(
                    id: accountID,
                    walletID: walletID,
                    networkID: networkID,
                    address:
                        "0x1111111111111111111111111111111111111111",
                    normalizedAddress:
                        "0x1111111111111111111111111111111111111111",
                    label: nil,
                    derivationPath: nil,
                    accountIndex: 0,
                    publicKey: nil,
                    isWatchOnly: true,
                    isEnabled: true,
                    createdAt: now,
                    updatedAt: now,
                    lastSyncedAt: now
                ).insert(db)
                try DBAssetRecord(
                    id: assetID,
                    networkID: networkID,
                    assetType: DatabaseAssetType.native.rawValue,
                    contractAddress: "",
                    normalizedContractAddress: "",
                    name: networkID,
                    symbol: "OLD",
                    decimals: 18,
                    trustWalletBlockchain: networkID,
                    trustWalletContractAddress: nil,
                    isVerified: true,
                    isSpam: false,
                    createdAt: now,
                    updatedAt: now,
                    metadataUpdatedAt: now
                ).insert(db)
                try DBAccountAssetRecord(
                    accountID: accountID,
                    assetID: assetID,
                    balance: "1",
                    balanceAtomic: "1000000000000000000",
                    fiatUSDValue: "1",
                    isEnabled: true,
                    isPinned: false,
                    isHidden: false,
                    sortOrder: 0,
                    firstSeenAt: now,
                    lastSeenAt: now,
                    updatedAt: now
                ).insert(db)
            }

            try WalletDatabase.retireRemovedEVMNetworks(
                database: db
            )
        }

        let remainingCounts = try await database.pool.read { db in
            (
                networks: try DBNetworkRecord
                    .filter(
                        Self.retiredNetworkIDs.contains(
                            Column("id")
                        )
                    )
                    .fetchCount(db),
                accounts: try DBWalletAccountRecord
                    .filter(
                        Self.retiredNetworkIDs.contains(
                            Column("networkID")
                        )
                    )
                    .fetchCount(db),
                assets: try DBAssetRecord
                    .filter(
                        Self.retiredNetworkIDs.contains(
                            Column("networkID")
                        )
                    )
                    .fetchCount(db),
                holdings: try DBAccountAssetRecord
                    .filter(
                        WalletDatabase.retiredEVMNetworkIDs
                            .map { "\($0):native" }
                            .contains(Column("assetID"))
                    )
                    .fetchCount(db)
            )
        }

        #expect(remainingCounts.networks == 0)
        #expect(remainingCounts.accounts == 0)
        #expect(remainingCounts.assets == 0)
        #expect(remainingCounts.holdings == 0)
    }
}

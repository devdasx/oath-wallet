import Foundation
import GRDB

extension WalletDatabase {
    static func registerTONMainnetMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v31_reintroduce_ton_mainnet") {
            database in
            let now = Date().timeIntervalSince1970
            try DBNetworkRecord(
                id: TONConstants.networkID,
                chainID: Int64(TONConstants.databaseChainID),
                nameKey: "network.ton.name",
                nativeSymbol: "TON",
                trustWalletBlockchain: WalletBlockchain.ton.rawValue,
                rpcProviderIdentifier: "tonapi",
                isMainnet: true,
                isEnabled: true,
                sortOrder: 10_300,
                createdAt: now,
                updatedAt: now
            ).save(database)
            try database.create(
                table: "tonJettonWallets",
                options: .ifNotExists
            ) { table in
                table.column("accountID", .text)
                    .notNull()
                    .references(
                        "walletAccounts",
                        onDelete: .cascade
                    )
                table.column("assetID", .text)
                    .notNull()
                    .references("assets", onDelete: .cascade)
                table.column("walletAddress", .text).notNull()
                table.column("updatedAt", .double).notNull()
                table.primaryKey(["accountID", "assetID"])
            }
        }
    }
}

import Foundation
import GRDB

extension WalletDatabase {
    static func registerSuiMainnetMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v33_add_sui_mainnet") { database in
            let now = Date().timeIntervalSince1970
            try DBNetworkRecord(
                id: SuiConstants.networkID,
                chainID: Int64(SuiConstants.databaseChainID),
                nameKey: "network.sui.name",
                nativeSymbol: SuiConstants.nativeSymbol,
                trustWalletBlockchain: WalletBlockchain.sui.rawValue,
                rpcProviderIdentifier: "ankr-sui-graphql",
                isMainnet: true,
                isEnabled: true,
                sortOrder: 10_400,
                createdAt: now,
                updatedAt: now
            ).save(database)
        }
    }
}

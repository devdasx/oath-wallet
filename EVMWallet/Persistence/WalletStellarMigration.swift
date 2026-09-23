import Foundation
import GRDB

extension WalletDatabase {
    static func registerStellarMainnetMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v37_add_stellar_mainnet") { database in
            let now = Date().timeIntervalSince1970
            try DBNetworkRecord(
                id: StellarConstants.networkID,
                chainID: Int64(StellarConstants.databaseChainID),
                nameKey: "network.stellar.name",
                nativeSymbol: StellarConstants.nativeSymbol,
                trustWalletBlockchain: WalletBlockchain.stellar.rawValue,
                rpcProviderIdentifier: "ankr-stellar-horizon",
                isMainnet: true,
                isEnabled: true,
                sortOrder: 10_700,
                createdAt: now,
                updatedAt: now
            ).save(database)
        }
    }
}

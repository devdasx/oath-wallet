import Foundation
import GRDB

extension WalletDatabase {
    static func registerXRPMainnetMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v34_add_xrp_mainnet") { database in
            let now = Date().timeIntervalSince1970
            try DBNetworkRecord(
                id: XRPConstants.networkID,
                chainID: Int64(XRPConstants.databaseChainID),
                nameKey: "network.xrp.name",
                nativeSymbol: XRPConstants.nativeSymbol,
                trustWalletBlockchain: WalletBlockchain.xrp.rawValue,
                rpcProviderIdentifier: "ankr-xrp-jsonrpc",
                isMainnet: true,
                isEnabled: true,
                sortOrder: 10_500,
                createdAt: now,
                updatedAt: now
            ).save(database)
        }
    }
}

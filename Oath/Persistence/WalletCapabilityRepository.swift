import GRDB

extension WalletDatabase {
    func walletCapabilities(
        walletID: String
    ) async throws -> WalletCapabilities {
        try await pool.read { database in
            guard
                let wallet = try DBWalletRecord.fetchOne(
                    database,
                    key: walletID
                )
            else {
                throw WalletDataStoreError.missingRecord
            }

            guard
                wallet.kind
                    == DatabaseWalletKind.importedPrivateKey.rawValue
            else {
                return .fullWallet
            }

            let enabledNetworkIDs = Set(
                try String.fetchAll(
                    database,
                    sql: """
                    SELECT networkID
                    FROM walletAccounts
                    WHERE walletID = ? AND isEnabled = 1
                    ORDER BY createdAt, networkID
                    """,
                    arguments: [walletID]
                )
            )

            guard
                let network = Self.privateKeyImportNetwork(
                    enabledNetworkIDs: enabledNetworkIDs
                )
            else {
                throw WalletDataStoreError.invalidState
            }
            return WalletCapabilities(scope: .privateKey(network))
        }
    }

    func selectedWalletCapabilities() async throws
        -> WalletCapabilities {
        guard let identity = try await selectedWalletIdentity() else {
            throw WalletDataStoreError.missingRecord
        }
        return try await walletCapabilities(walletID: identity.walletID)
    }

    static func privateKeyImportNetwork(
        enabledNetworkIDs: Set<String>
    ) -> PrivateKeyImportNetwork? {
        let exactNetworks: [PrivateKeyImportNetwork] = [
            .aptos,
            .stellar,
            .bitcoin,
            .litecoin,
            .dogecoin,
            .bitcoinCash,
            .tron,
            .solana,
            .ton,
            .sui,
            .xrp,
            .near
        ]
        if let exact = exactNetworks.first(where: {
            enabledNetworkIDs.contains($0.networkID)
        }) {
            return exact
        }

        let evmNetworkIDs = Set(
            ReceiveNetworkCatalog.all
                .filter {
                    ![
                        WalletBlockchain.tron,
                        .aptos,
                        .stellar,
                        .solana,
                        .ton,
                        .sui,
                        .xrp,
                        .near,
                        .bitcoin,
                        .bitcoincash,
                        .litecoin,
                        .dogecoin
                    ].contains($0.blockchain)
                }
                .map(\.id)
        )
        return enabledNetworkIDs.isDisjoint(with: evmNetworkIDs)
            ? nil
            : .evm
    }
}

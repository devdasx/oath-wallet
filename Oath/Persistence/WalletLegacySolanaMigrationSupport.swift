import GRDB

func solanaMetadataRowCount(_ database: Database) throws -> Int {
    try Int.fetchOne(
        database,
        sql: """
        SELECT COALESCE(SUM(rowCount), 0)
        FROM (
            SELECT COUNT(*) AS rowCount FROM networks WHERE id = 'solana'
            UNION ALL SELECT COUNT(*) FROM walletAccounts WHERE networkID = 'solana'
            UNION ALL SELECT COUNT(*) FROM assets WHERE networkID = 'solana'
            UNION ALL SELECT COUNT(*) FROM accountAssets
                WHERE accountID IN (
                    SELECT id FROM walletAccounts WHERE networkID = 'solana'
                )
                OR assetID IN (
                    SELECT id FROM assets WHERE networkID = 'solana'
                )
            UNION ALL SELECT COUNT(*) FROM assetPrices
                WHERE assetID IN (
                    SELECT id FROM assets WHERE networkID = 'solana'
                )
            UNION ALL SELECT COUNT(*) FROM marketSnapshots
                WHERE assetID IN (
                    SELECT id FROM assets WHERE networkID = 'solana'
                )
            UNION ALL SELECT COUNT(*) FROM transactions WHERE networkID = 'solana'
            UNION ALL SELECT COUNT(*) FROM transactionTransfers
                WHERE transactionID IN (
                    SELECT id FROM transactions WHERE networkID = 'solana'
                )
            UNION ALL SELECT COUNT(*) FROM nftCollections WHERE networkID = 'solana'
            UNION ALL SELECT COUNT(*) FROM nftItems
                WHERE collectionID IN (
                    SELECT id FROM nftCollections WHERE networkID = 'solana'
                )
            UNION ALL SELECT COUNT(*) FROM accountNFTHoldings
                WHERE accountID IN (
                    SELECT id FROM walletAccounts WHERE networkID = 'solana'
                )
            UNION ALL SELECT COUNT(*) FROM contactAddresses WHERE networkID = 'solana'
            UNION ALL SELECT COUNT(*) FROM dappPermissions
                WHERE chainID = -501
                   OR accountID IN (
                        SELECT id FROM walletAccounts WHERE networkID = 'solana'
                   )
            UNION ALL SELECT COUNT(*) FROM priceAlerts
                WHERE assetID IN (
                    SELECT id FROM assets WHERE networkID = 'solana'
                )
            UNION ALL SELECT COUNT(*) FROM syncStates
                WHERE accountID IN (
                    SELECT id FROM walletAccounts WHERE networkID = 'solana'
                )
            UNION ALL SELECT COUNT(*) FROM pendingOperations
                WHERE accountID IN (
                    SELECT id FROM walletAccounts WHERE networkID = 'solana'
                )
            UNION ALL SELECT COUNT(*) FROM transactionTags
                WHERE transactionID IN (
                    SELECT id FROM transactions WHERE networkID = 'solana'
                )
            UNION ALL SELECT COUNT(*) FROM notifications
                WHERE relatedTransactionID IN (
                    SELECT id FROM transactions WHERE networkID = 'solana'
                )
        )
        """
    ) ?? 0
}

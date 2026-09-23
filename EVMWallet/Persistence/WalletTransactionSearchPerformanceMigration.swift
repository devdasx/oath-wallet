import GRDB

extension WalletDatabase {
    static func registerTransactionSearchPerformanceMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v69_transaction_search_relevant_updates") { database in
            try installTransactionSearchUpdateTriggers(database)
        }
    }

    /// Price/fee enrichment updates entire GRDB records. Only changes to fields
    /// actually indexed by FTS should delete/reinsert the search document.
    /// Related metadata triggers rebuild their matching documents directly,
    /// rather than relying on a no-op transaction timestamp update.
    static func installTransactionSearchUpdateTriggers(_ database: Database) throws {
        let transactionColumns = [
            "id", "accountID", "assetID", "assetSymbol", "kind", "status",
            "direction", "networkID", "transactionHash", "fromAddress", "toAddress",
            "counterpartyAddress", "methodName", "displayDetail", "displayTime"
        ]
        let changes = transactionColumns.map { "old.\($0) IS NOT new.\($0)" }
            .joined(separator: " OR ")
        try database.execute(sql: """
            DROP TRIGGER transactionSearch_update;
            DROP TRIGGER transactionSearch_asset_update;
            DROP TRIGGER transactionSearch_network_update;

            CREATE TRIGGER transactionSearch_update
            AFTER UPDATE ON transactions
            WHEN \(changes)
            BEGIN
                DELETE FROM transactionSearchIndex WHERE transactionID = old.id;
                \(transactionSearchInsertSQL(where: "t.id = new.id"))
            END;

            CREATE TRIGGER transactionSearch_asset_update
            AFTER UPDATE OF name, symbol, contractAddress ON assets
            WHEN old.name IS NOT new.name OR old.symbol IS NOT new.symbol
                OR old.contractAddress IS NOT new.contractAddress
            BEGIN
                DELETE FROM transactionSearchIndex
                WHERE transactionID IN (SELECT id FROM transactions WHERE assetID = new.id);
                \(transactionSearchInsertSQL(where: "t.assetID = new.id"))
            END;

            CREATE TRIGGER transactionSearch_network_update
            AFTER UPDATE OF nativeSymbol, trustWalletBlockchain ON networks
            WHEN old.nativeSymbol IS NOT new.nativeSymbol
                OR old.trustWalletBlockchain IS NOT new.trustWalletBlockchain
            BEGIN
                DELETE FROM transactionSearchIndex
                WHERE transactionID IN (SELECT id FROM transactions WHERE networkID = new.id);
                \(transactionSearchInsertSQL(where: "t.networkID = new.id"))
            END;
            """)
    }

    private static func transactionSearchInsertSQL(where predicate: String) -> String {
        """
        INSERT INTO transactionSearchIndex(transactionID, accountID, title, body)
        SELECT t.id, t.accountID, t.assetSymbol,
            trim(t.kind || ' ' || t.status || ' ' || t.direction || ' '
                || t.networkID || ' ' || t.transactionHash || ' '
                || COALESCE(t.fromAddress, '') || ' ' || COALESCE(t.toAddress, '') || ' '
                || COALESCE(t.counterpartyAddress, '') || ' ' || COALESCE(t.methodName, '') || ' '
                || t.displayDetail || ' ' || t.displayTime || ' '
                || COALESCE(a.name, '') || ' ' || COALESCE(a.symbol, '') || ' '
                || COALESCE(a.contractAddress, '') || ' ' || COALESCE(n.nativeSymbol, '') || ' '
                || COALESCE(n.trustWalletBlockchain, '') || ' ' || COALESCE(note.note, ''))
        FROM transactions AS t
        LEFT JOIN assets AS a ON a.id = t.assetID
        LEFT JOIN networks AS n ON n.id = t.networkID
        LEFT JOIN transactionNotes AS note ON note.transactionID = t.id
        WHERE \(predicate);
        """
    }
}

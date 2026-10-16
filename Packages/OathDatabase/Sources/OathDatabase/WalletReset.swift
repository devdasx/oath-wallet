import Foundation
import GRDB

extension OathDatabase {
    /// A confirmed reset survives process termination. Settings, market data,
    /// and migration markers belong to the installation, not to a wallet.
    public func pendingWalletReset() async throws -> String? {
        try await pool.read { try String.fetchOne($0, sql: "SELECT value FROM metadata WHERE key='walletReset'") }
    }

    @discardableResult
    public func beginWalletReset() async throws -> String {
        try await pool.write { db in
            if let existing = try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='walletReset'") { return existing }
            let id = UUID().uuidString
            try db.execute(sql: "INSERT INTO metadata(key,value) VALUES('walletReset',?)", arguments: [id])
            return id
        }
    }

    /// Erase the complete ledger, including rows shared by multiple wallets.
    /// Deleting only wallets would leave transactions, transfers and UTXOs.
    public func eraseWalletData(resetID: String) async throws {
        try await pool.write { db in
            try Self.requireReset(resetID, db: db)
            try Self.eraseWalletRows(db)
        }
        // Reclaim old pages and truncate the WAL off the UI thread. A failed
        // checkpoint leaves the journal intact and is safely retried at launch.
        try await pool.vacuum()
        try await pool.writeWithoutTransaction { db in _ = try db.checkpoint(.truncate) }
    }

    /// Shared local-ledger cleanup. Call only inside the caller's transaction.
    static func eraseWalletRows(_ db: Database) throws {
        try db.execute(sql: """
                DELETE FROM utxos;
                DELETE FROM wallets;
                DELETE FROM transactions;
                DELETE FROM contacts;
                INSERT INTO notesSearch(notesSearch) VALUES('rebuild');
                INSERT INTO contactsSearch(contactsSearch) VALUES('rebuild');
                DELETE FROM settings WHERE key='activeWalletID';
                """)
    }

    public func finishWalletReset(resetID: String) async throws {
        try await pool.write { db in
            try Self.requireReset(resetID, db: db)
            for table in Self.walletDataTables {
                guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0 else {
                    throw StoreError.invalidTransition
                }
            }
            try db.execute(sql: "DELETE FROM metadata WHERE key='walletReset'")
        }
    }

    static let walletDataTables = ["walletConnectSolanaSubmissions", "wallets", "walletPortfolioFilters", "accounts", "balances", "transactions", "transfers", "activity",
        "transactionConflictKeys", "transactionEvidence", "sends", "utxos", "accountUTXOs", "receives", "notes", "labels", "labelAssignments", "syncCursors",
        "thorchainSendPlans", "thorchainSync", "thorchainHistory", "thorchainPendingEvents", "permissionScans", "permissionRemovals", "permissionBatchItems", "balanceSnapshots", "cloudBackups", "contacts", "contactAddresses", "trackedAssets", "bitcoinWallets", "bitcoinAddresses",
        "bitcoinHistory", "bitcoinTransactions", "ankrSync", "ankrResponses", "ankrAssets", "ankrActivity", "solanaReceiveAddresses", "solanaSync", "solanaHoldings", "solanaHistoryCursors", "solanaTransactions", "solanaActivity", "tronSync", "tronHoldings", "tronHistoryCursors", "tronTransactions", "tronPages", "tonSync", "tonHoldings", "tonHistoryCursors", "tonTransactions", "tonPages", "aptosSync", "aptosHoldings", "aptosHistoryCursors", "aptosTransactions", "aptosPages", "suiSync", "suiHoldings", "suiHistoryCursors", "suiTransactions", "suiPages", "nearSync", "nearHoldings", "nearHistoryCursors", "nearTransactions", "nearEvents", "nearPages", "xrplSync", "xrplHoldings", "xrplHistoryCursors", "xrplTransactions", "xrplPages", "stellarSync", "stellarHoldings", "stellarHistoryCursors", "stellarTransactions", "stellarEvents", "stellarPages", "indexedEVMSync", "indexedEVMHoldings", "indexedEVMHistoryCursors", "indexedEVMEvents", "indexedEVMPages", "hyperevmSync", "hyperevmHoldings", "hyperevmHistoryCursors", "hyperevmEvents", "hyperevmPages", "robinhoodSync", "robinhoodHoldings", "robinhoodHistoryCursors", "robinhoodEvents", "robinhoodPages", "arcSync", "arcHoldings", "arcHistoryCursors", "arcEvents", "arcPages"]

    private static func requireReset(_ id: String, db: Database) throws {
        guard try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='walletReset'") == id else {
            throw StoreError.invalidTransition
        }
    }
}

import Foundation
import GRDB

/// Automatic cleanup of an authenticated empty destination must never erase
/// skipped legacy recovery material. Bind that policy to the durable reset ID.
public struct EmptyWalletReset: Codable, Sendable {
    public let resetID: String
    public let legacyFingerprint: String?
}

extension OathDatabase {
    /// A confirmed reset survives process termination. Settings, market data,
    /// and migration markers belong to the installation, not to a wallet.
    public func pendingWalletReset() async throws -> String? {
        try await pool.read { try String.fetchOne($0, sql: "SELECT value FROM metadata WHERE key='walletReset'") }
    }

    public func pendingLegacyRecoveryReset() async throws -> Bool {
        try await pool.read { db in
            guard let id = try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='walletResetRecovery'") else { return false }
            try Self.requireReset(id, db: db)
            return true
        }
    }

    public func pendingEmptyWalletReset() async throws -> EmptyWalletReset? {
        try await pool.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='walletResetEmpty'") else { return nil }
            let reset = try JSONDecoder().decode(EmptyWalletReset.self, from: data)
            try Self.requireReset(reset.resetID, db: db)
            return reset
        }
    }

    @discardableResult
    public func beginEmptyWalletReset(legacyFingerprint: String?) async throws -> String {
        try await pool.write { db in
            guard try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='walletReset'") == nil else {
                throw StoreError.invalidTransition
            }
            let id = UUID().uuidString
            let context = EmptyWalletReset(resetID: id, legacyFingerprint: legacyFingerprint)
            try db.execute(sql: "INSERT INTO metadata(key,value) VALUES('walletReset',?)", arguments: [id])
            try db.execute(sql: "INSERT INTO metadata(key,value) VALUES('walletResetEmpty',?)", arguments: [try JSONEncoder().encode(context)])
            return id
        }
    }

    @discardableResult
    public func beginWalletReset(legacyRecovery: Bool = false) async throws -> String {
        try await pool.write { db in
            let id = try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='walletReset'") ?? UUID().uuidString
            try db.execute(sql: "INSERT OR IGNORE INTO metadata(key,value) VALUES('walletReset',?)", arguments: [id])
            if legacyRecovery {
                try db.execute(sql: "INSERT OR REPLACE INTO metadata(key,value) VALUES('walletResetRecovery',?)", arguments: [id])
            }
            return id
        }
    }

    /// Erase the complete ledger, including rows shared by multiple wallets.
    /// Deleting only wallets would leave transactions, transfers and UTXOs.
    public func eraseWalletData(resetID: String) async throws {
        try await pool.write { db in
            try Self.requireReset(resetID, db: db)
            try Self.eraseWalletRows(db)
            if try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='walletResetRecovery'") == resetID
                || Data.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='walletResetEmpty'") != nil {
                // Recovery reset returns to a fresh app, including preferences
                // and public caches. Ordinary authenticated reset keeps them.
                try db.execute(sql: """
                    DELETE FROM settings;
                    DELETE FROM prices;
                    DELETE FROM exchangeRates;
                    DELETE FROM exchangeRateMetadata;
                    DELETE FROM publicMarketCache;
                    DELETE FROM assets;
                    DELETE FROM networks;
                    DELETE FROM metadata WHERE key NOT IN ('walletReset', 'walletResetRecovery', 'walletResetEmpty');
                    """)
            }
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
            try db.execute(sql: "DELETE FROM metadata WHERE key IN ('walletReset', 'walletResetRecovery', 'walletResetEmpty')")
        }
    }

    static let walletDataTables = ["walletConnectXrplSubmissions", "walletConnectStellarSubmissions", "walletConnectNearGrants", "walletConnectNearSubmissions", "walletConnectSuiSubmissions", "walletConnectTonSubmissions", "walletConnectSolanaSubmissions", "wallets", "hiddenAssets", "walletPortfolioFilters", "walletAccounts", "accounts", "receiveQRCodes", "balances", "transactions", "transfers", "activity",
        "transactionConflictKeys", "transactionEvidence", "sends", "utxos", "accountUTXOs", "receives", "notes", "labels", "labelAssignments", "syncCursors",
        "polkadotSendPlans", "thorchainSendPlans", "thorchainSync", "thorchainHistory", "thorchainPendingEvents", "permissionScans", "permissionRemovals", "permissionBatchItems", "balanceSnapshots", "cloudBackups", "contacts", "contactAddresses", "trackedAssets", "bitcoinWallets", "bitcoinAddresses",
        "bitcoinHistory", "bitcoinTransactions", "ankrSync", "ankrResponses", "ankrAssets", "ankrActivity", "solanaReceiveAddresses", "solanaSync", "solanaHoldings", "solanaHistoryCursors", "solanaTransactions", "solanaActivity", "tronSync", "tronHoldings", "tronHistoryCursors", "tronTransactions", "tronPages", "tonSync", "tonHoldings", "tonHistoryCursors", "tonTransactions", "tonPages", "aptosSync", "aptosHoldings", "aptosHistoryCursors", "aptosTransactions", "aptosPages", "suiSync", "suiHoldings", "suiHistoryCursors", "suiTransactions", "suiPages", "nearSync", "nearHoldings", "nearHistoryCursors", "nearTransactions", "nearEvents", "nearPages", "xrplSync", "xrplHoldings", "xrplHistoryCursors", "xrplTransactions", "xrplPages", "polkadotSync", "polkadotHoldings", "polkadotHistory", "polkadotEvents", "stellarSync", "stellarHoldings", "stellarHistoryCursors", "stellarTransactions", "stellarEvents", "stellarPages", "indexedEVMSync", "indexedEVMHoldings", "indexedEVMHistoryCursors", "indexedEVMEvents", "indexedEVMPages", "hyperevmSync", "hyperevmHoldings", "hyperevmHistoryCursors", "hyperevmEvents", "hyperevmPages", "robinhoodSync", "robinhoodHoldings", "robinhoodHistoryCursors", "robinhoodEvents", "robinhoodPages", "arcSync", "arcHoldings", "arcHistoryCursors", "arcEvents", "arcPages"]

    private static func requireReset(_ id: String, db: Database) throws {
        guard try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='walletReset'") == id else {
            throw StoreError.invalidTransition
        }
    }
}

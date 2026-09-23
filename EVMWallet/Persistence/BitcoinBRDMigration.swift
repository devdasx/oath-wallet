import GRDB

extension WalletDatabase {
    static func registerBitcoinBRDMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v74_bitcoin_brd_accounts", foreignKeyChecks: .deferred) { database in
            // Rebuild constrained tables with foreign keys disabled by GRDB for
            // this transaction, then checked before commit. Child rows, balances,
            // selections and opaque Keychain references retain their identities.
            for table in ["bitcoinHDAccounts", "bitcoinHDPreferences", "bitcoinHDKeyCaches", "bitcoinHDAddressSelections"] {
                guard let original = try String.fetchOne(
                    database, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
                    arguments: [table]
                ) else { throw BitcoinHDWalletDatabaseError.invalidDescriptor }
                let temporary = table + "_brd"
                let updated = original
                    .replacingOccurrences(of: "CREATE TABLE \(table)", with: "CREATE TABLE \(temporary)")
                    .replacingOccurrences(of: "'bip44', 'bip49', 'bip84', 'bip86'",
                                          with: "'bip44', 'bip49', 'bip84', 'bip86', 'brdLegacy', 'brdSegwit'")
                    .replacingOccurrences(of: "UNIQUE(walletID, accountPath)",
                                          with: "UNIQUE(walletID, addressType, accountPath)")
                guard updated != original else { throw BitcoinHDWalletDatabaseError.invalidDescriptor }
                try database.execute(sql: updated)
                try database.execute(sql: "INSERT INTO \(temporary) SELECT * FROM \(table)")
                try database.execute(sql: "DROP TABLE \(table)")
                try database.execute(sql: "ALTER TABLE \(temporary) RENAME TO \(table)")
            }
        }
    }
}

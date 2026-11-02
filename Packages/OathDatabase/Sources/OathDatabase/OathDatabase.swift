import OathDiagnostics
import Foundation
import GRDB

/// One instance/pool per file. Public I/O is async; opening and migrating also
/// happen off the caller's actor. Only committed immutable values reach the UI.
public final class OathDatabase: Sendable {
    let pool: DatabasePool

    public static func open(at url: URL) async throws -> OathDatabase {
        try await Task.detached(priority: .userInitiated) { try OathDatabase(url: url) }.value
    }

    private init(url: URL) throws {
        guard url.isFileURL else { throw StoreError.invalidDatabaseLocation }
        let directory = url.deletingLastPathComponent()
        let manager = FileManager.default
        for item in [directory, url] {
            do {
                if try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                    throw StoreError.invalidDatabaseLocation
                }
            } catch CocoaError.fileReadNoSuchFile {
                // First launch: paths are created below. Other I/O errors must propagate.
            } catch CocoaError.fileNoSuchFile {
                // First launch: paths are created below.
            } catch {
                OathDiagnostics.record(error, component: "storage", operation: "inspect_database_path")
                throw error
            }
        }
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        // Public wallet metadata and already-signed journals must remain usable
        // by BGAppRefresh after the first device unlock. Private signing keys
        // live in the separate vault and retain their existing protection.
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
        // createDirectory does not update an existing directory's attributes.
        try manager.setAttributes(attributes, ofItemAtPath: directory.path)
        #if os(iOS)
        // Existing WAL databases must be accessible before opening/migrating.
        for path in [url.path, url.path + "-wal", url.path + "-shm"] where manager.fileExists(atPath: path) {
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path)
        }
        #endif
        var folder = directory
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try folder.setResourceValues(resources)
        var configuration = Configuration()
        configuration.label = "org.oathwallet.database"
        configuration.foreignKeysEnabled = true
        configuration.maximumReaderCount = 4
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            db.add(function: HistorySearch.function)
            db.add(function: ReceiveQRImage.function)
            db.add(function: HistoryFilter.amountFunction)
            db.add(function: HistorySafety.metadataFunction)
            // Correctness of durable local send state takes precedence over
            // benchmarks that disable fsync. GRDB owns WAL/checkpoint access.
            try db.execute(sql: "PRAGMA synchronous = FULL")
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }
        pool = try DatabasePool(path: url.path, configuration: configuration)
        try Schema.migrator.migrate(pool)
        for path in [url.path, url.path + "-wal", url.path + "-shm"] where manager.fileExists(atPath: path) {
            var fileAttributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
            #if os(iOS)
            fileAttributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
            #endif
            try manager.setAttributes(fileAttributes, ofItemAtPath: path)
        }
    }

    /// Bootstrap bundled definitions and refresh their display branding in one
    /// transaction. Identity, precision, derivation, ordering and user-enabled
    /// state survive an app update; all UI reads still come from the database.
    public func seed(networks: [NetworkRecord], assets: [AssetRecord]) async throws {
        try await pool.write { db in
            for network in networks {
                try network.insert(db, onConflict: .ignore)
                try db.execute(sql: """
                    UPDATE networks SET name = ?, symbol = ?, logo = ?
                    WHERE id = ? AND (name IS NOT ? OR symbol IS NOT ? OR logo IS NOT ?)
                    """, arguments: [network.name, network.symbol, network.logo, network.id,
                                     network.name, network.symbol, network.logo])
            }
            for asset in assets {
                if let existing = try AssetRecord.fetchOne(db, key: asset.id),
                   existing.networkID != asset.networkID || existing.reference != asset.reference {
                    throw StoreError.conflictingIdentity
                }
                try asset.insert(db, onConflict: .ignore)
                try HistorySafety.trust(networkID: asset.networkID, reference: asset.reference,
                    decimals: asset.decimals, source: "bundled", observedAt: 0, db: db)
                try db.execute(sql: """
                    UPDATE assets SET name = ?, symbol = ?, logo = ?
                    WHERE id = ? AND (name IS NOT ? OR symbol IS NOT ? OR logo IS NOT ?)
                    """, arguments: [asset.name, asset.symbol, asset.logo, asset.id,
                                     asset.name, asset.symbol, asset.logo])
            }
        }
    }

    public func networks(enabledOnly: Bool = true) async throws -> [NetworkRecord] {
        try await pool.read { db in
            let rows = try NetworkRecord.fetchAll(db, sql: "SELECT * FROM networks WHERE (? = 0 OR enabled = 1)",
                                                 arguments: [enabledOnly])
            let active = try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key='activeWalletID'")
            let holdings = try active.map { try Self.snapshot(db, walletID: $0, currency: "USD").holdings } ?? []
            let order = PortfolioAssetOrder(holdings)
            return AssetOrdering.sorted(rows) { order.key(networkID: $0.id, name: $0.name) }
        }
    }
    public func saveNetwork(_ network: NetworkRecord) async throws {
        try await pool.write { db in try network.upsert(db) }
    }
    public func saveAsset(_ asset: AssetRecord) async throws {
        try await pool.write { db in
            if let existing = try AssetRecord.fetchOne(db, key: asset.id),
               existing.networkID != asset.networkID || existing.reference != asset.reference {
                throw StoreError.conflictingIdentity
            }
            try asset.upsert(db)
        }
    }

    public func importWalletIfNeeded(_ wallet: WalletRecord, accounts: [AccountRecord]) async throws {
        guard ["electrum", "electrum2fa", "aezeed", "hd", "imported", "privateKey", "watchOnly", "passphrase", "bitcoinMultisig", "litecoinMultisig", "bitcoinCashMultisig", "dogecoinMultisig", "evmMultisig", "tronMultisig", "solanaMultisig", "xrplMultisig", "stellarMultisig", "aptosMultisig", "tonMultisig", "thorchainMultisig", "nearMultisig", "suiMultisig"].contains(wallet.kind), wallet.createdAt.isFinite,
              !wallet.id.isEmpty, !wallet.vaultReference.isEmpty else { throw StoreError.invalidValue("wallet") }
        guard !["aezeed", "electrum", "electrum2fa"].contains(wallet.kind) || (!accounts.isEmpty && accounts.allSatisfy { $0.networkID == "bitcoin" }) else { throw StoreError.invalidValue("aezeed network") }
        try await pool.write { db in
            if let existing = try WalletRecord.fetchOne(db, key: wallet.id) {
                guard existing.vaultReference == wallet.vaultReference else { throw StoreError.conflictingIdentity }
            } else {
                var wallet = wallet
                let group = wallet.nameGroup ?? WalletRecord.inferredNameGroup(kind: wallet.kind, networkIDs: accounts.map(\.networkID))
                guard ["main", "imported", "restored"].contains(group) || (group == "multisig" && ["bitcoinMultisig", "litecoinMultisig", "bitcoinCashMultisig", "dogecoinMultisig", "evmMultisig", "tronMultisig", "solanaMultisig", "xrplMultisig", "stellarMultisig", "aptosMultisig", "tonMultisig", "thorchainMultisig", "nearMultisig", "suiMultisig"].contains(wallet.kind)) || (group == "passphrase" && ["passphrase", "electrum", "electrum2fa"].contains(wallet.kind)) ||
                        (wallet.kind == "privateKey" && accounts.contains { "network:" + $0.networkID == group }) else {
                    throw StoreError.invalidValue("wallet name group")
                }
                wallet.nameGroup = group
                wallet.sortOrder = (try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM wallets") ?? -1) + 1
                if group != "passphrase" || wallet.nameIndex <= 0 {
                    wallet.nameIndex = (try Int.fetchOne(db, sql: "SELECT MAX(nameIndex) FROM wallets WHERE nameGroup=?", arguments: [group]) ?? (group == "passphrase" ? 0 : -1)) + 1
                }
                try wallet.insert(db)
            }
            for account in accounts {
                guard account.walletID == wallet.id else { throw StoreError.conflictingIdentity }
                if let existing = try AccountRecord.fetchOne(db, key: account.id) {
                    guard existing.walletID == account.walletID, existing.networkID == account.networkID,
                          existing.address == account.address, existing.derivationPath == account.derivationPath,
                          existing.accountIndex == account.accountIndex else { throw StoreError.conflictingIdentity }
                } else { try account.insert(db) }
            }
        }
    }
    public func wallets(includingDeleted: Bool = false) async throws -> [WalletRecord] {
        try await pool.read { try WalletRecord.fetchAll($0, sql: "SELECT * FROM wallets " + (includingDeleted ? "" : "WHERE deletedAt IS NULL ") + "ORDER BY sortOrder, createdAt, id") }
    }
    public func observeWallets(includingDeleted: Bool = false) -> AsyncThrowingStream<[WalletRecord], Error> {
        stream { try WalletRecord.fetchAll($0, sql: "SELECT * FROM wallets " + (includingDeleted ? "" : "WHERE deletedAt IS NULL ") + "ORDER BY sortOrder, createdAt, id") }
    }
    public func wallet(_ id: String) async throws -> WalletRecord? {
        try await pool.read { try WalletRecord.fetchOne($0, key: id) }
    }
    public func accounts(walletID: String) async throws -> [AccountRecord] {
        try await pool.read { try Self.accounts($0, walletID: walletID) }
    }
    static func accounts(_ db: Database, walletID: String) throws -> [AccountRecord] {
        try AccountRecord.fetchAll(db, sql: "SELECT * FROM walletAccounts WHERE walletID = ? ORDER BY networkID, id", arguments: [walletID])
    }
    public func renameWallet(_ id: String, name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WalletRecord.isValidName(name) else {
            throw StoreError.invalidValue("wallet name")
        }
        try await pool.write { db in
            try db.execute(sql: "UPDATE wallets SET name = ?, confirmedName = ? WHERE id = ?", arguments: [name, name, id])
            guard db.changesCount == 1 else { throw StoreError.missingRecord }
        }
    }
    public func markBackedUp(_ id: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE wallets SET backedUp = 1 WHERE id = ?", arguments: [id])
            guard db.changesCount == 1 else { throw StoreError.missingRecord }
        }
    }
    /// Name and artwork are one committed edit; observations never see a new
    /// name paired with the previous color. Nil restores the original palette.
    public func customizeWallet(_ id: String, name: String, colorHex: String?, keepDefaultName: Bool = false) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WalletRecord.isValidName(name) else { throw StoreError.invalidValue("wallet name") }
        if let colorHex {
            guard colorHex.utf8.count == 6,
                  colorHex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else {
                throw StoreError.invalidValue("wallet color")
            }
        }
        try Task.checkCancellation()
        try await pool.write { db in
            if keepDefaultName {
                guard try WalletRecord.fetchOne(db, key: id)?.name.isEmpty == true else { throw StoreError.invalidTransition }
            }
            try db.execute(sql: "UPDATE wallets SET name=?, confirmedName=?, colorHex=?, needsCustomization=0 WHERE id=?", arguments: [keepDefaultName ? "" : name, name, colorHex, id])
            guard db.changesCount == 1 else { throw StoreError.missingRecord }
        }
    }
    /// Removes public metadata only. The caller must separately erase the
    /// matching protected vault. Foreign keys remove wallet-owned child rows.
    public func deleteWalletMetadata(_ id: String) async throws {
        try await pool.write { db in
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM sends WHERE walletID=? AND state IN ('queued','signed','broadcast') LIMIT 1", arguments: [id]) == nil else {
                throw StoreError.invalidTransition
            }
            let transactionIDs = try String.fetchAll(db, sql: """
                SELECT transactionID FROM activity WHERE walletID=?
                UNION SELECT transactionID FROM sends WHERE walletID=? AND transactionID IS NOT NULL
                """, arguments: [id, id])
            try db.execute(sql: "DELETE FROM wallets WHERE id = ?", arguments: [id])
            try db.execute(sql: """
                DELETE FROM utxos WHERE reservedBy IS NULL AND NOT EXISTS (
                    SELECT 1 FROM accountUTXOs o WHERE o.networkID=utxos.networkID
                    AND o.transactionHash=utxos.transactionHash AND o.outputIndex=utxos.outputIndex
                )
                """)
            for transactionID in transactionIDs {
                try db.execute(sql: """
                    DELETE FROM transactions WHERE id=?
                        AND NOT EXISTS (SELECT 1 FROM activity WHERE transactionID=transactions.id)
                        AND NOT EXISTS (SELECT 1 FROM sends WHERE transactionID=transactions.id)
                    """, arguments: [transactionID])
            }
            try db.execute(sql: "DELETE FROM settings WHERE key = 'activeWalletID' AND value = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [Self.multisigNoticeKey(id)])
            try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [Self.multisigWarningKey(id)])
        }
    }

    public func settings() async throws -> [String: String] {
        try await pool.read { try Self.settings($0) }
    }
    static func settings(_ db: Database) throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: try SettingRecord.fetchAll(db).map { ($0.key, $0.value) })
    }
    public func setSetting(_ key: String, value: String?) async throws {
        guard !key.isEmpty, key.count <= 200 else { throw StoreError.invalidValue("setting key") }
        if key == "currency", let value { try Validation.currency(value) }
        if key == "balancesHidden", let value, !["true", "false"].contains(value) { throw StoreError.invalidValue("balance visibility") }
        if key == AppAppearance.settingKey, let value, AppAppearance(rawValue: value) == nil {
            throw StoreError.invalidValue("appearance")
        }
        try await pool.write { db in
            if let value {
                if key == "activeWalletID", try WalletRecord.fetchOne(db, key: value) == nil { throw StoreError.missingRecord }
                try SettingRecord(key: key, value: value, updatedAt: Date.now.timeIntervalSince1970).upsert(db)
            } else { try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key]) }
        }
    }
    /// The database, rather than a potentially stale UI snapshot, decides the
    /// next value when several taps/writers arrive before observation delivery.
    public func toggleBalanceVisibility() async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO settings(key,value,updatedAt) VALUES ('balancesHidden','true',?)
                ON CONFLICT(key) DO UPDATE SET value=CASE settings.value WHEN 'true' THEN 'false' ELSE 'true' END,
                    updatedAt=excluded.updatedAt
                """, arguments: [Date.now.timeIntervalSince1970])
        }
    }
    /// A retry-safe, one-way migration. Old preferences cease to be a read source
    /// even when the legacy value is absent or changed later.
    public func migrateLegacySettings(_ values: [String: String]) async throws {
        try await pool.write { db in
            guard try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'legacySettingsV1'") == nil else { return }
            for (key, value) in values {
                try SettingRecord(key: key, value: value, updatedAt: Date.now.timeIntervalSince1970).insert(db, onConflict: .ignore)
            }
            try db.execute(sql: "INSERT INTO metadata(key,value) VALUES ('legacySettingsV1','done')")
        }
    }
    public func observeSettings() -> AsyncThrowingStream<[String: String], Error> {
        stream { try Self.settings($0) }
    }

    func stream<Value: Equatable & Sendable>(
        _ fetch: @escaping @Sendable (Database) throws -> Value
    ) -> AsyncThrowingStream<Value, Error> {
        let observation = ValueObservation.tracking(fetch).removeDuplicates()
        let values = observation.values(in: pool, scheduling: .async(onQueue: .global(qos: .userInitiated)), bufferingPolicy: .bufferingNewest(1))
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    for try await value in values {
                        try Task.checkCancellation()
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch { OathDiagnostics.record(error); continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

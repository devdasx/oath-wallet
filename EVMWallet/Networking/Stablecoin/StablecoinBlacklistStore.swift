import Foundation
import GRDB

struct StablecoinBlacklistRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable, Identifiable {
    static let databaseTableName = "stablecoinBlacklistChecks"
    let walletID: String
    let accountID: String
    let networkID: String
    let contract: String
    let address: String
    let symbol: String
    let isBlacklisted: Bool
    let checkedAt: Double
    var id: String { [walletID, networkID, contract, address].joined(separator: ":") }
}

struct StablecoinCheckJob: Sendable {
    let walletID: String
    let accountID: String
    let address: String
    let target: StablecoinBlacklistTarget
}

struct StablecoinCheckPlan: Sendable {
    let jobs: [StablecoinCheckJob]
    let accountsComplete: Bool
}

extension WalletDatabase {
    static func registerStablecoinBlacklistMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v_stablecoin_blacklist_checks") { db in
            try db.execute(sql: """
                CREATE TABLE stablecoinBlacklistChecks (
                    walletID TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                    accountID TEXT NOT NULL REFERENCES walletAccounts(id) ON DELETE CASCADE,
                    networkID TEXT NOT NULL, contract TEXT NOT NULL, address TEXT NOT NULL,
                    symbol TEXT NOT NULL, isBlacklisted INTEGER NOT NULL CHECK(isBlacklisted IN (0,1)),
                    checkedAt REAL NOT NULL,
                    PRIMARY KEY(walletID, networkID, contract, address)
                )
                """)
        }
    }

    func pendingStablecoinChecks(walletID: String, targets: [StablecoinBlacklistTarget]) async throws -> [StablecoinCheckJob] {
        try await stablecoinCheckPlan(walletID: walletID, targets: targets).jobs
    }

    func stablecoinCheckPlan(walletID: String, targets: [StablecoinBlacklistTarget]) async throws -> StablecoinCheckPlan {
        let capabilities = try await walletCapabilities(walletID: walletID)
        return try await pool.read { db in
            guard let wallet = try DBWalletRecord.fetchOne(db, key: walletID),
                  wallet.archivedAt == nil else { return StablecoinCheckPlan(jobs: [], accountsComplete: true) }
            let accounts = try DBWalletAccountRecord
                .filter(Column("walletID") == walletID)
                .filter(Column("isEnabled") == true).fetchAll(db)
            let evmAccount = accounts.first { $0.networkID == "eth" }
                ?? accounts.first { ReceiveNetworkCatalog.network(for: $0.networkID)?.blockchain.isEVM == true }
            let cached = try StablecoinBlacklistRecord.filter(Column("walletID") == walletID).fetchAll(db)
            var accountsComplete = true
            let jobs: [StablecoinCheckJob] = targets.compactMap { target in
                guard target.method != nil, capabilities.permits(networkID: target.networkID) else { return nil }
                let account = accounts.first { $0.networkID == target.networkID }
                    ?? (target.networkID != "tron" && capabilities.usesEVMWalletAddress ? evmAccount : nil)
                guard let account else { accountsComplete = false; return nil }
                let address = target.networkID == "tron" ? account.address : account.address.lowercased()
                guard !cached.contains(where: {
                    $0.networkID == target.networkID && $0.contract == target.contract
                        && $0.address == address
                }) else { return nil }
                return StablecoinCheckJob(walletID: walletID, accountID: account.id, address: address, target: target)
            }
            return StablecoinCheckPlan(jobs: jobs, accountsComplete: accountsComplete)
        }
    }

    func storeStablecoinCheck(_ record: StablecoinBlacklistRecord) async throws {
        try Task.checkCancellation()
        try await pool.write { db in
            try Task.checkCancellation()
            guard let wallet = try DBWalletRecord.fetchOne(db, key: record.walletID), wallet.archivedAt == nil,
                  let account = try DBWalletAccountRecord.fetchOne(db, key: record.accountID),
                  account.walletID == record.walletID, account.isEnabled,
                  (record.networkID == "tron" ? account.address : account.address.lowercased()) == record.address
            else { return }
            // First successful true OR false wins. No transient state can erase it.
            try record.insert(db, onConflict: .ignore)
        }
    }

    static func confirmedStablecoinChecks(in db: Database) throws -> [StablecoinBlacklistRecord] {
        try StablecoinBlacklistRecord.fetchAll(db, sql: """
            SELECT c.* FROM stablecoinBlacklistChecks c
            JOIN wallets w ON w.id = c.walletID
            JOIN walletAccounts a ON a.id = c.accountID AND a.walletID = c.walletID
            WHERE w.archivedAt IS NULL AND a.isEnabled = 1 AND c.isBlacklisted = 1
              AND c.address = CASE WHEN c.networkID = 'tron' THEN a.address ELSE lower(a.address) END
            ORDER BY c.networkID, c.symbol, c.contract
            """)
    }

    func confirmedStablecoinChecks() -> AsyncValueObservation<[StablecoinBlacklistRecord]> {
        ValueObservation.tracking { db in try Self.confirmedStablecoinChecks(in: db) }
            .values(in: pool, bufferingPolicy: .bufferingNewest(1))
    }
}

import CryptoKit
import Foundation
import GRDB
import OathAnkr
import OathDiagnostics

public struct StablecoinSecurityState: Equatable, Sendable {
    public let acknowledged: Bool
    public let restricted: [StablecoinRestrictionToken]
}

extension OathDatabase {
    static func restrictionProbeID(account: StablecoinRestrictionAccount, token: StablecoinRestrictionToken) -> String {
        // Local public-account identity only. Never upload it as diagnostic context.
        SHA256.hash(data: Data((account.network + "|" + account.address + "|" + token.reference).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    private static func requireSecurityWallet(_ db: Database, _ walletID: String) throws {
        guard let wallet = try WalletRecord.fetchOne(db, key: walletID), wallet.deletedAt == nil else { throw StoreError.missingRecord }
    }
    /// Commit BEFORE the request. A terminated/offline attempt stays unknown,
    /// never "clear", and is not automatically retried on the next Home render.
    func claimRestrictionChecks(walletID: String, account: StablecoinRestrictionAccount) async throws -> [StablecoinRestrictionToken] {
        try await pool.write { db in
            try Self.requireSecurityWallet(db, walletID)
            var claimed: [StablecoinRestrictionToken] = []
            for token in StablecoinRestrictionRegistry.tokens(network: account.network) {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO stablecoinSecurityChecks(walletID,probeID,networkID,reference,outcome)
                    VALUES(?,?,?,?,'unavailable')
                    """, arguments: [walletID, Self.restrictionProbeID(account: account, token: token), token.network, token.reference])
                if db.changesCount == 1 { claimed.append(token) }
            }
            return claimed
        }
    }
    func saveRestrictionChecks(walletID: String, account: StablecoinRestrictionAccount, results: [StablecoinRestrictionResult]) async throws {
        try await pool.write { db in
            try Self.requireSecurityWallet(db, walletID)
            for result in results {
                guard result.token.network == account.network, StablecoinRestrictionRegistry.tokens.contains(result.token) else { throw StoreError.invalidValue("restriction identity") }
                try db.execute(sql: """
                    UPDATE stablecoinSecurityChecks SET outcome=? WHERE walletID=? AND probeID=?
                    """, arguments: [result.outcome.rawValue, walletID, Self.restrictionProbeID(account: account, token: result.token)])
            }
        }
    }
    public func stablecoinSecurityState(walletID: String) async throws -> StablecoinSecurityState {
        try await pool.read { db in
            try Self.requireSecurityWallet(db, walletID)
            let acknowledged = try Bool.fetchOne(db, sql: "SELECT acknowledged FROM stablecoinSecurityNotices WHERE walletID=?", arguments: [walletID]) ?? false
            let rows = try Row.fetchAll(db, sql: "SELECT DISTINCT networkID,reference FROM stablecoinSecurityChecks WHERE walletID=? AND outcome='restricted'", arguments: [walletID])
            let identities = Set(rows.map { ($0["networkID"] as String) + ":" + ($0["reference"] as String) })
            return .init(acknowledged: acknowledged, restricted: StablecoinRestrictionRegistry.tokens.filter { identities.contains($0.id) })
        }
    }
    public func acknowledgeStablecoinSecurity(walletID: String) async throws {
        try await pool.write { db in
            try Self.requireSecurityWallet(db, walletID)
            try db.execute(sql: """
                INSERT INTO stablecoinSecurityNotices(walletID,acknowledged) VALUES(?,1)
                ON CONFLICT(walletID) DO UPDATE SET acknowledged=1
                """, arguments: [walletID])
        }
    }
}

/// Work survives view disappearance and wallet switches. No UI actor or vault
/// dependency; only public addresses and local database records enter this actor.
public actor StablecoinSecurityScan {
    public static let shared = StablecoinSecurityScan()
    private struct Key: Hashable {
        let database: ObjectIdentifier
        let walletID: String
        let accounts: [StablecoinRestrictionAccount]
    }
    private var running: [Key: Task<Void, Never>] = [:]
    private let permits = StablecoinSecurityPermits()
    public init() {}

    public func run(database: OathDatabase, walletID: String, accounts: [StablecoinRestrictionAccount],
                    checker: StablecoinRestrictionCheck) async {
        let unique = Array(Set(accounts)).sorted { ($0.network, $0.address) < ($1.network, $1.address) }
        let key = Key(database: ObjectIdentifier(database), walletID: walletID, accounts: unique)
        if let task = running[key] { await task.value; return }
        // No timer/polling and no unbounded queue from rapid wallet switches.
        guard running.count < 8 else { return }
        let permits = permits
        let task = Task.detached(priority: .utility) {
            for start in stride(from: 0, to: unique.count, by: 4) {
                await withTaskGroup(of: Void.self) { group in
                    for account in unique[start..<min(start + 4, unique.count)] where !StablecoinRestrictionRegistry.tokens(network: account.network).isEmpty {
                        group.addTask {
                            await OathDiagnostics.$operationID.withValue(UUID()) {
                                await OathDiagnostics.$chain.withValue(account.network) {
                                    await permits.acquire()
                                    do {
                                        let tokens = try await database.claimRestrictionChecks(walletID: walletID, account: account)
                                        if !tokens.isEmpty {
                                            let results = await checker.check(account, tokens: tokens)
                                            try await database.saveRestrictionChecks(walletID: walletID, account: account, results: results)
                                        }
                                    } catch {
                                        // A wallet removed while its read-only scan runs is normal teardown.
                                        if (error as? StoreError) != .missingRecord {
                                            OathDiagnostics.record(error, component: "stablecoin_security", operation: "persist_check")
                                        }
                                    }
                                    await permits.release()
                                }
                            }
                        }
                    }
                }
            }
        }
        running[key] = task
        await task.value
        running[key] = nil
    }
}

private actor StablecoinSecurityPermits {
    private var available = 4
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        if waiting.isEmpty { available += 1 } else { waiting.removeFirst().resume() }
    }
}

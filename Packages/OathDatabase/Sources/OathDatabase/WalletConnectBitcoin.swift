import Foundation
import CryptoKit
import GRDB
import OathBitcoin

public struct WalletConnectBitcoinSubmission: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "walletConnectBitcoinSubmissions"
    public let id: String, walletID: String, accountID: String, chain: String, fingerprint: String, hash: String
    public let planData: Data, signedData: Data
    public let createdAt: Double
    public var state: String
    public func decoded() throws -> (BitcoinConnectPlan,BitcoinConnectSigned) {
        let plan = try JSONDecoder().decode(BitcoinConnectPlan.self,from:planData), signed = try JSONDecoder().decode(BitcoinConnectSigned.self,from:signedData)
        guard plan.request.network.chain == chain, plan.request.fingerprint == fingerprint, signed.txid == hash else { throw BitcoinConnectError.changed }
        try BitcoinConnectSigning.verify(signed,plan:plan)
        return (plan,signed)
    }
}
extension OathDatabase {
    static func migrateWalletConnectBitcoin(_ db: Database) throws {
        try db.execute(sql:"""
            CREATE TABLE walletConnectBitcoinSubmissions (
                id TEXT PRIMARY KEY NOT NULL, walletID TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, chain TEXT NOT NULL,
                fingerprint TEXT NOT NULL, hash TEXT NOT NULL, planData BLOB NOT NULL, signedData BLOB NOT NULL,
                createdAt DOUBLE NOT NULL, state TEXT NOT NULL
            );
            CREATE TABLE walletConnectBitcoinInputs (
                submissionID TEXT NOT NULL REFERENCES walletConnectBitcoinSubmissions(id) ON DELETE CASCADE,
                chain TEXT NOT NULL, txid TEXT NOT NULL, vout INTEGER NOT NULL,
                PRIMARY KEY(submissionID,txid,vout)
            );
            CREATE TRIGGER wc_bitcoin_reservation BEFORE UPDATE OF reservedBy ON utxos
            WHEN NEW.networkID='bitcoin' AND NEW.reservedBy IS NOT NULL AND EXISTS (
                SELECT 1 FROM walletConnectBitcoinInputs i JOIN walletConnectBitcoinSubmissions s ON s.id=i.submissionID
                WHERE i.chain='bip122:000000000019d6689c085ae165831e93' AND i.txid=NEW.transactionHash AND i.vout=NEW.outputIndex
                AND s.state IN ('signed','unknown','accepted')
            ) BEGIN SELECT RAISE(ABORT,'Bitcoin input reserved'); END;
            """)
        for operation in ["INSERT","UPDATE"] {
            try db.execute(sql:"""
                CREATE TRIGGER reset_guard_walletConnectBitcoinSubmissions_\(operation) BEFORE \(operation) ON walletConnectBitcoinSubmissions
                WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                BEGIN SELECT RAISE(ABORT,'Wallet reset in progress'); END;
                """)
        }
    }
    public func walletConnectBitcoinAddresses(accountID: String) async throws -> [BitcoinDerivedAddress] {
        guard let state = try await bitcoinState(accountID:accountID), state.descriptor.network == .bitcoin else { throw BitcoinConnectError.wrongAccount }
        return try await pool.read { db in
            var result: [BitcoinDerivedAddress] = []
            for branch in state.descriptor.branches {
                let funded = try Data.fetchAll(db,sql:"""
                    SELECT DISTINCT b.detail FROM bitcoinAddresses b JOIN utxos u ON u.script=b.script AND u.networkID='bitcoin'
                    WHERE b.accountID=? AND b.branchID=? AND u.spent=0 ORDER BY b.addressIndex LIMIT 4001
                    """,arguments:[accountID,branch.id]).map { try JSONDecoder().decode(BitcoinDerivedAddress.self,from:$0) }
                result += funded
                let last = state.requiredThrough[branch.id]
                guard last == nil || last! < 0x7fff_fffd else { throw BitcoinConnectError.tooLarge }
                let through = last.map { $0 + 1 } ?? 0
                let first = try BitcoinKeys.addresses(branch:branch,range:0..<1)
                let next = branch.isHD ? try BitcoinKeys.addresses(branch:branch,range:through..<(through + 2)) : []
                result += first + next
                guard result.count <= 4_000 else { throw BitcoinConnectError.tooLarge }
            }
            var seen = Set<String>()
            return result.filter { seen.insert($0.script).inserted }.sorted {
                let left = $0.type == .nativeSegwit && $0.change == 0 && $0.index == 0
                let right = $1.type == .nativeSegwit && $1.change == 0 && $1.index == 0
                return left != right ? left : $0.path < $1.path
            }
        }
    }
    public func walletConnectBitcoinSubmission(_ id: String) async throws -> WalletConnectBitcoinSubmission? {
        try await pool.read { try WalletConnectBitcoinSubmission.fetchOne($0,key:id) }
    }
    public func walletConnectBitcoinUTXORevision(accountID: String) async throws -> Data {
        try await pool.read { db in
            let rows = try Row.fetchAll(db,sql:"""
                SELECT DISTINCT u.transactionHash,u.outputIndex,u.value,u.script
                FROM utxos u JOIN bitcoinAddresses b ON b.script=u.script
                WHERE b.accountID=? AND u.networkID='bitcoin' AND u.spent=0
                ORDER BY u.transactionHash,u.outputIndex LIMIT 4001
                """,arguments:[accountID])
            guard rows.count <= 4_000 else { throw BitcoinConnectError.tooLarge }
            var digest = SHA256()
            for row in rows {
                let hash: String = row["transactionHash"], index: Int = row["outputIndex"]
                let value: Int64 = row["value"]
                let script: String = row["script"]
                digest.update(data:Data("\(hash):\(index):\(value):\(script)\n".utf8))
            }
            return Data(digest.finalize())
        }
    }
    public func pendingWalletConnectBitcoinSubmissions() async throws -> [WalletConnectBitcoinSubmission] {
        try await pool.read { try WalletConnectBitcoinSubmission.fetchAll($0,sql:"""
            SELECT s.* FROM walletConnectBitcoinSubmissions s JOIN wallets w ON w.id=s.walletID
            WHERE s.state IN ('signed','unknown','accepted') AND w.deletedAt IS NULL
            AND NOT EXISTS(SELECT 1 FROM metadata WHERE key='walletReset') ORDER BY s.createdAt LIMIT 32
            """) }
    }
    public func journalWalletConnectBitcoin(id: String, walletID: String, accountID: String, plan: BitcoinConnectPlan, signed: BitcoinConnectSigned) async throws -> WalletConnectBitcoinSubmission {
        try BitcoinConnectSigning.verify(signed,plan:plan)
        guard let hash = signed.txid, plan.request.broadcasts else { throw BitcoinConnectError.changed }
        let planData = try JSONEncoder().encode(plan), signedData = try JSONEncoder().encode(signed)
        return try await pool.write { db in
            if let old = try WalletConnectBitcoinSubmission.fetchOne(db,key:id) {
                guard old.walletID == walletID, old.accountID == accountID, old.fingerprint == plan.request.fingerprint, try old.decoded().1 == signed else { throw BitcoinConnectError.changed }
                return old
            }
            guard let account = try AccountRecord.fetchOne(db,key:accountID), account.networkID == "bitcoin", account.walletID == walletID,
                  try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM wallets WHERE id=? AND deletedAt IS NULL)",arguments:[walletID]) == true,
                  try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM walletConnectBitcoinSubmissions WHERE state IN ('signed','unknown','accepted')") ?? 0 < 32 else { throw BitcoinConnectError.busy }
            for point in plan.outpoints {
                let parts = point.split(separator:":")
                guard parts.count == 2, let vout = Int(parts[1]) else { throw BitcoinConnectError.wrongInput }
                guard try Bool.fetchOne(db,sql:"""
                    SELECT EXISTS(SELECT 1 FROM walletConnectBitcoinInputs i JOIN walletConnectBitcoinSubmissions s ON s.id=i.submissionID
                    WHERE i.chain=? AND i.txid=? AND i.vout=? AND s.state IN ('signed','unknown','accepted'))
                    """,arguments:[plan.request.network.chain,String(parts[0]),vout]) == false else { throw BitcoinConnectError.busy }
                if plan.request.network == .mainnet {
                    guard try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM utxos WHERE networkID='bitcoin' AND transactionHash=? AND outputIndex=? AND (reservedBy IS NOT NULL OR spent=1))",arguments:[String(parts[0]),vout]) == false else { throw BitcoinConnectError.busy }
                }
            }
            let row = WalletConnectBitcoinSubmission(id:id,walletID:walletID,accountID:accountID,chain:plan.request.network.chain,fingerprint:plan.request.fingerprint,hash:hash,planData:planData,signedData:signedData,createdAt:Date.now.timeIntervalSince1970,state:"signed")
            try row.insert(db)
            for point in plan.outpoints {
                let parts = point.split(separator:":")
                try db.execute(sql:"INSERT INTO walletConnectBitcoinInputs VALUES(?,?,?,?)",arguments:[id,plan.request.network.chain,String(parts[0]),Int(parts[1])!])
            }
            return row
        }
    }
    public func settleWalletConnectBitcoin(_ id: String, status: BitcoinConnectClient.Status) async throws {
        try await pool.write { db in
            guard var row = try WalletConnectBitcoinSubmission.fetchOne(db,key:id), row.state != "confirmed",
                  !(row.state == "accepted" && status == .unknown) else { return }
            row.state = status.rawValue; try row.update(db)
            if status == .confirmed, row.chain == BitcoinConnectNetwork.mainnet.chain {
                try db.execute(sql:"""
                    UPDATE utxos SET spent=1,updatedAt=? WHERE networkID='bitcoin' AND EXISTS (
                        SELECT 1 FROM walletConnectBitcoinInputs i WHERE i.submissionID=?
                        AND i.txid=utxos.transactionHash AND i.vout=utxos.outputIndex
                    )
                    """,arguments:[Date.now.timeIntervalSince1970,id])
            }
        }
    }
}

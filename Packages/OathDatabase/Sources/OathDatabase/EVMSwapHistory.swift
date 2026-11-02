import Foundation
import GRDB
import OathAnkr
import OathDiagnostics

public struct EVMSwapCandidate: Sendable {
    public let accountID: String, transactionID: String, networkID: String, owner: String, hash: String
    public let generation: Int64
    public let cachedEvidence: Data?
}

extension OathDatabase {
    static func installSwapHistory(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE evmHistorySwaps (
            accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            transactionID TEXT NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
            version INTEGER NOT NULL, generation INTEGER NOT NULL, blockHash TEXT,
            inputAssetID TEXT REFERENCES assets(id), outputAssetID TEXT REFERENCES assets(id),
            spent TEXT, received TEXT, evidence BLOB NOT NULL, checkedAt DOUBLE NOT NULL,
            PRIMARY KEY(accountID,transactionID)
        );
        CREATE VIEW validHistorySwaps AS
        SELECT c.*,owner.walletID,owner.networkID,t.hash,t.timestamp FROM evmHistorySwaps c
        JOIN accounts owner ON owner.id=c.accountID AND owner.syncGeneration=c.generation
        JOIN transactions t ON t.id=c.transactionID
        LEFT JOIN transactionEvidence e ON e.accountID=c.accountID AND e.transactionID=c.transactionID
        WHERE c.version=1 AND c.inputAssetID IS NOT NULL AND c.outputAssetID IS NOT NULL
        AND COALESCE(e.outcome,t.state)='confirmed' AND lower(t.blockHash)=c.blockHash
        AND EXISTS(SELECT 1 FROM visibleActivity a WHERE a.accountID=c.accountID AND a.transactionID=c.transactionID AND a.assetID=c.inputAssetID)
        AND EXISTS(SELECT 1 FROM visibleActivity a WHERE a.accountID=c.accountID AND a.transactionID=c.transactionID AND a.assetID=c.outputAssetID);
        CREATE VIEW projectedHistoryActivity AS
        SELECT a.id,a.walletID,a.accountID,a.networkID,a.transactionID,a.assetID,a.direction,a.amountAtomic,
            a.counterparty,a.timestamp,a.sortTimestamp,NULL AS outputAssetID,NULL AS received
        FROM visibleActivity a WHERE NOT EXISTS(SELECT 1 FROM validHistorySwaps c
            WHERE c.accountID=a.accountID AND c.transactionID=a.transactionID)
        UNION ALL
        SELECT 'swap:'||c.accountID||':'||c.networkID||':'||lower(c.hash),c.walletID,c.accountID,c.networkID,
            c.transactionID,c.inputAssetID,'swap',c.spent,'',c.timestamp,
            (SELECT MAX(a.sortTimestamp) FROM visibleActivity a WHERE a.accountID=c.accountID AND a.transactionID=c.transactionID),c.outputAssetID,c.received
        FROM validHistorySwaps c;
        """)
    }

    /// Include one-sided bridge legs and zero-value contract calls, not just swaps.
    /// A negative cache is revisited after five minutes; version changes reuse
    /// cached evidence. Queries are bounded and never block displaying history.
    public func swapHistoryCandidates(walletID: String, limit: Int = 24) async throws -> [EVMSwapCandidate] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT DISTINCT owner.id AS accountID,owner.networkID,owner.address,owner.syncGeneration,
                    t.id AS transactionID,t.hash,c.evidence,c.version
                FROM walletAccounts owner JOIN activity a ON a.accountID=owner.id
                JOIN transactions t ON t.id=a.transactionID
                JOIN networks n ON n.id=owner.networkID AND n.family='evm'
                LEFT JOIN evmHistorySwaps c ON c.accountID=owner.id AND c.transactionID=t.id
                WHERE owner.walletID=? AND t.state IN ('confirmed','failed')
                AND (c.version IS NULL OR c.version<>? OR c.generation<>owner.syncGeneration
                    OR COALESCE(lower(t.blockHash),'')<>COALESCE(c.blockHash,'') OR c.checkedAt<?)
                ORDER BY c.checkedAt ASC,t.timestamp DESC LIMIT ?
                """, arguments: [walletID, EVMHistorySwap.version, Date().timeIntervalSince1970 - 300, max(1,min(limit,100))]).map {
                EVMSwapCandidate(accountID: $0["accountID"], transactionID: $0["transactionID"], networkID: $0["networkID"],
                    owner: $0["address"], hash: $0["hash"], generation: $0["syncGeneration"],
                    cachedEvidence: ($0["version"] as Int?) != EVMHistorySwap.version ? $0["evidence"] : nil)
            }
        }
    }

    private func retainingHistoryExecution(_ incoming: EVMHistoryEvidence, candidate: EVMSwapCandidate) async throws -> EVMHistoryEvidence {
        guard incoming.trace == nil || incoming.pools?.isEmpty != false else { return incoming }
        let cached = try await pool.read { db in
            try Data.fetchOne(db, sql: "SELECT evidence FROM evmHistorySwaps WHERE accountID=? AND transactionID=? AND generation=?",
                arguments: [candidate.accountID, candidate.transactionID, candidate.generation])
        }
        guard let cached, cached.count <= EVMHistoryEvidence.maximumEncodedBytes else { return incoming }
        let previous: EVMHistoryEvidence
        do { previous = try JSONDecoder().decode(EVMHistoryEvidence.self, from: cached) }
        catch {
            OathDiagnostics.record(error, component: "history_execution", operation: "cache_decode", context: ["chain": candidate.networkID])
            return incoming
        }
        // A tracing/archive outage must not erase already verified evidence.
        // Reuse only for the identical transaction and inclusion receipt.
        guard previous.transaction == incoming.transaction, previous.receipt == incoming.receipt else { return incoming }
        return .init(transaction: incoming.transaction, receipt: incoming.receipt,
            trace: incoming.trace ?? previous.trace,
            pools: incoming.pools?.isEmpty != false ? previous.pools : incoming.pools)
    }

    public func saveSwapHistoryEvidence(_ incoming: EVMHistoryEvidence, candidate: EVMSwapCandidate) async throws {
        let evidence = try await retainingHistoryExecution(incoming, candidate: candidate)
        guard let network = EVMSendNetwork(rawValue: candidate.networkID) else { return }
        let swap = try EVMHistorySwap.classify(transaction: evidence.transaction, receipt: evidence.receipt,
                                              owner: candidate.owner, chainID: network.chainID, trace: evidence.trace, pools: evidence.pools ?? [])
        let bridge = try EVMHistoryBridge.classify(evidence, owner: candidate.owner, chainID: network.chainID)
        let contract = try EVMHistoryContractCall.classify(transaction: evidence.transaction, receipt: evidence.receipt,
                                                           owner: candidate.owner, chainID: network.chainID)
        let raw = try JSONEncoder().encode(evidence)
        guard raw.count <= EVMHistoryEvidence.maximumEncodedBytes else { throw StoreError.invalidValue("swap evidence size") }
        try Task.checkCancellation()
        try await pool.write { db in
            guard let owner = try AccountRecord.fetchOne(db,key: candidate.accountID),
                  owner.syncGeneration == candidate.generation,
                  let tx = try TransactionRecord.fetchOne(db,key: candidate.transactionID), tx.hash.lowercased() == candidate.hash.lowercased() else { throw StoreError.staleSync }
            // Never let an older receipt overwrite a more recent indexing result.
            let block = evidence.receipt["blockHash"].string?.lowercased()
            guard let block, tx.blockHash == nil || tx.blockHash?.lowercased() == block else {
                // A disappeared/reorganized receipt must immediately stop hiding
                // the original records. The indexer owns the new block/state.
                try db.execute(sql: "DELETE FROM evmHistorySwaps WHERE accountID=? AND transactionID=?",
                               arguments: [candidate.accountID,candidate.transactionID])
                return
            }
            if tx.blockHash == nil {
                // Some indexers omit blockHash. Only fill that missing field
                // when the receipt agrees with their confirmed block height.
                guard ["confirmed", "failed"].contains(tx.state), let height = evidence.receipt["blockNumber"].string,
                      let number = Int64(try AnkrQuantity.decimal(height)), tx.blockHeight == number else { return }
                try db.execute(sql: "UPDATE transactions SET blockHash=? WHERE id=? AND blockHash IS NULL", arguments: [block,tx.id])
            }
            func asset(_ ref: String?) throws -> String? {
                guard let ref else { return nil }
                return try String.fetchOne(db, sql: "SELECT id FROM assets WHERE networkID=? AND lower(reference)=?", arguments: [candidate.networkID,ref])
            }
            let input = try asset(swap?.input), output = try asset(swap?.output)
            try db.execute(sql: """
                INSERT INTO evmHistorySwaps(accountID,transactionID,version,generation,blockHash,inputAssetID,outputAssetID,spent,received,evidence,checkedAt,bridgeKey,bridgeDirection,bridgeAssetID,bridgeAmount,bridgeProtocol,contractKind)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(accountID,transactionID) DO UPDATE SET
                    version=excluded.version,generation=excluded.generation,blockHash=excluded.blockHash,
                    inputAssetID=excluded.inputAssetID,outputAssetID=excluded.outputAssetID,spent=excluded.spent,
                    received=excluded.received,evidence=excluded.evidence,checkedAt=excluded.checkedAt,
                    bridgeKey=excluded.bridgeKey,bridgeDirection=excluded.bridgeDirection,bridgeAssetID=excluded.bridgeAssetID,
                    bridgeAmount=excluded.bridgeAmount,bridgeProtocol=excluded.bridgeProtocol,contractKind=excluded.contractKind
                """, arguments: [candidate.accountID,candidate.transactionID,EVMHistorySwap.version,candidate.generation,block,
                                   input,output,swap?.spent,swap?.received,raw,Date().timeIntervalSince1970,
                                   bridge?.key,bridge?.direction,try asset(bridge?.asset),bridge?.amount,bridge?.protocolName,contract?.rawValue])
        }
    }
}

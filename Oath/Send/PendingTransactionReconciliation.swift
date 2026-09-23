import Foundation
import CryptoKit
import GRDB

/// Public transaction evidence only. Retaining the original inputs/nonce lets
/// us identify a conflict even after the original disappears from an indexer.
struct PendingTransactionEvidence: Sendable {
    var rawTransaction: String?
    var nonce: Int64?
}

extension WalletDatabase {
    func pendingEvidence(_ target: SendPendingStatusTarget) async throws -> PendingTransactionEvidence {
        try await pool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT rawTransaction, nonce FROM pendingTransactionEvidence
                WHERE accountID = ? AND networkID = ? AND transactionHash = ?
                """, arguments: [target.receipt.accountID, target.receipt.networkID, target.normalizedHash])
            return PendingTransactionEvidence(rawTransaction: row?["rawTransaction"],
                nonce: (row?["nonce"] as Int64?) ?? target.nonce)
        }
    }

    func savePendingEvidence(_ value: PendingTransactionEvidence, target: SendPendingStatusTarget) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO pendingTransactionEvidence(accountID, networkID, transactionHash, rawTransaction, nonce)
                VALUES (?, ?, ?, ?, ?) ON CONFLICT(accountID, networkID, transactionHash) DO UPDATE SET
                rawTransaction = COALESCE(excluded.rawTransaction, pendingTransactionEvidence.rawTransaction),
                nonce = COALESCE(excluded.nonce, pendingTransactionEvidence.nonce)
                """, arguments: [target.receipt.accountID, target.receipt.networkID, target.normalizedHash,
                    value.rawTransaction, value.nonce])
        }
    }

    /// Missing is recoverable and never frees a spend reservation. A confirmed
    /// conflict is persisted by updateSubmittedSendStatus after this observation.
    @discardableResult
    func recordPendingObservation(_ status: SendTransactionNetworkStatus,
                                  target: SendPendingStatusTarget, now: Date = Date()) async throws -> Bool {
        try await pool.write { db in
            let arguments: StatementArguments = [target.receipt.accountID, target.receipt.networkID, target.normalizedHash]
            let previous = try Row.fetchOne(db, sql: """
                SELECT firstMissingAt, missingCount FROM pendingTransactionEvidence
                WHERE accountID = ? AND networkID = ? AND transactionHash = ?
                """, arguments: arguments)
            let firstMissing: Double? = status == .notFound
                ? min((previous?["firstMissingAt"] as Double?) ?? now.timeIntervalSince1970, now.timeIntervalSince1970) : nil
            let count = status == .notFound ? ((previous?["missingCount"] as Int?) ?? 0) + 1 : 0
            let visible = status == .notFound && (count < 2 || now.timeIntervalSince1970 - (firstMissing ?? 0) < 15)
                ? SendTransactionNetworkStatus.pending : status
            let observation = visible == .canceled ? "replaced" : visible.rawValue
            let old = try String.fetchOne(db, sql: """
                SELECT COALESCE(observedStatus, status) FROM transactions
                WHERE accountID = ? AND networkID = ?
                    AND (transactionHash = ? OR (? = 1 AND lower(transactionHash) = lower(?))) LIMIT 1
                """, arguments: [target.receipt.accountID, target.receipt.networkID,
                    target.receipt.transactionHash, !target.hasCaseSensitiveHash, target.receipt.transactionHash])
            let changed = old != observation
            try db.execute(sql: """
                INSERT INTO pendingTransactionEvidence(accountID, networkID, transactionHash,
                    firstMissingAt, missingCount, lastCheckedAt, balanceNeedsRefresh, balanceInvalidatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(accountID, networkID, transactionHash) DO UPDATE SET
                    firstMissingAt = excluded.firstMissingAt, missingCount = excluded.missingCount,
                    lastCheckedAt = excluded.lastCheckedAt,
                    balanceNeedsRefresh = MAX(pendingTransactionEvidence.balanceNeedsRefresh, excluded.balanceNeedsRefresh),
                    balanceInvalidatedAt = CASE WHEN excluded.balanceNeedsRefresh = 1 THEN excluded.balanceInvalidatedAt
                        ELSE pendingTransactionEvidence.balanceInvalidatedAt END
                """, arguments: [target.receipt.accountID, target.receipt.networkID, target.normalizedHash,
                    firstMissing, count, now.timeIntervalSince1970, changed || status.isTerminal, now.timeIntervalSince1970])
            if changed {
                try db.execute(sql: """
                    UPDATE transactions SET observedStatus = ?, updatedAt = ?,
                        replacementTransactionHash = CASE WHEN ? = 'pending' THEN NULL ELSE replacementTransactionHash END
                    WHERE accountID = ? AND networkID = ?
                        AND (transactionHash = ? OR (? = 1 AND lower(transactionHash) = lower(?))) AND status = 'pending'
                    """, arguments: [observation, now.timeIntervalSince1970, observation, target.receipt.accountID,
                        target.receipt.networkID, target.receipt.transactionHash, !target.hasCaseSensitiveHash, target.receipt.transactionHash])
            }
            return changed
        }
    }

    func recordReplacement(_ hash: String, target: SendPendingStatusTarget) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                UPDATE transactions SET replacementTransactionHash = ?
                WHERE accountID = ? AND networkID = ?
                    AND (transactionHash = ? OR (? = 1 AND lower(transactionHash) = lower(?))) AND status = 'pending'
                """, arguments: [hash, target.receipt.accountID, target.receipt.networkID,
                    target.receipt.transactionHash, !target.hasCaseSensitiveHash, target.receipt.transactionHash])
        }
    }
}

struct PendingTransactionReconciler: Sendable {
    let database: WalletDatabase
    private static let enrichmentPool = SendStatusRequestPool(limit: 4)
    private let bitcoin = PendingBitcoinConflictReader()

    func status(for target: SendPendingStatusTarget) async throws -> SendTransactionNetworkStatus {
        try await Self.enrichmentPool.read(key: target.id, network: target.receipt.networkID) {
            try await performStatus(for: target)
        }
    }

    private func performStatus(for target: SendPendingStatusTarget) async throws -> SendTransactionNetworkStatus {
        let status: SendTransactionNetworkStatus
        if target.isTONHistory {
            status = try await SendStatusRequestPool.shared.read(key: "ton-history:" + target.id, network: "ton") {
                try await NotificationTONStatusProvider().status(hash: target.receipt.transactionHash,
                    accountAddress: target.accountAddress, contractAddress: target.contractAddress,
                    sender: target.receipt.fromAddress.isEmpty ? nil : target.receipt.fromAddress,
                    recipient: target.receipt.toAddress.isEmpty ? nil : target.receipt.toAddress)
            }
        } else { status = try await SendStatusRequestPool.shared.status(for: target.receipt) }
        if status.isTerminal { return status }
        var evidence = try await database.pendingEvidence(target)
        if let chain = BitcoinFamilyChain(rawValue: target.receipt.networkID) {
            if evidence.rawTransaction == nil, status == .pending {
                // Enrichment failing must not suppress a valid status. Retry it
                // on the next poll. Stored bytes are checked against the txid.
                if let raw = try? await BitcoinFamilyElectrumClient.shared.call(chain: chain,
                    method: "blockchain.transaction.get", params: [AnyEncodable(target.normalizedHash), AnyEncodable(false)]).string,
                   let parsed = BitcoinRawTransaction(hex: raw), parsed.transactionID == target.normalizedHash {
                    evidence.rawTransaction = raw
                    try await database.savePendingEvidence(evidence, target: target)
                }
            }
            if status == .notFound {
                if let conflict = try? await bitcoin.conflict(chain: chain, hash: target.normalizedHash,
                                                            originalRaw: evidence.rawTransaction) {
                    try await database.recordReplacement(conflict.hash, target: target)
                    // A mempool replacement is still reversible. Only a mined
                    // conflicting spender releases reserved resources.
                    return conflict.confirmed ? .canceled : .replaced
                }
            }
        } else if case .evm = try SendTransactionStatusRoute.resolve(networkID: target.receipt.networkID),
                  SendAddressValidator.isValidEVMAddress(target.receipt.fromAddress) {
            let client = try SendEVMRPCClient(networkID: target.receipt.networkID)
            if evidence.nonce == nil, status == .pending,
               let value = try? await client.transactionNonce(hash: target.receipt.transactionHash,
                                                             fromAddress: target.receipt.fromAddress),
               let nonce = Int64(value) {
                evidence.nonce = nonce
                try await database.savePendingEvidence(evidence, target: target)
            }
            if status == .notFound, let nonce = evidence.nonce, nonce >= 0,
               let count = try? await client.confirmedTransactionCount(address: target.receipt.fromAddress) {
                let used = try SendAtomicAmount.decimalFromHexQuantity(count)
                if let confirmedNonce = UInt64(used), confirmedNonce > UInt64(nonce) {
                    // Check the exact receipt again after the nonce read to
                    // avoid calling a just-mined original a replacement.
                    guard let verified = try? await client.transactionStatus(hash: target.receipt.transactionHash) else { return status }
                    if verified == .notFound,
                       let replacement = try? await client.confirmedReplacement(hash: target.receipt.transactionHash,
                           sender: target.receipt.fromAddress, nonce: nonce) {
                        let replacementStatus = try? await client.transactionStatus(hash: replacement)
                        // Failed executions also consume their nonce. Recheck
                        // the original after identifying the conflicting block.
                        if replacementStatus == .confirmed || replacementStatus == .failed {
                            guard let original = try? await client.transactionStatus(hash: target.receipt.transactionHash) else { return status }
                            guard original == .notFound else { return original }
                            try await database.recordReplacement(replacement, target: target)
                            return .canceled
                        }
                    }
                    return verified
                }
            }
        }
        return status
    }
}

struct PendingBitcoinConflict: Equatable, Sendable {
    let hash: String
    let confirmed: Bool
}

/// Exact input conflicts, never balance differences or a truncated receive
/// history. Bitcoin also has a public RBF record for already-disappeared txids.
struct PendingBitcoinConflictReader: Sendable {
    typealias Executor = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let executor: Executor
    private let exactStatus: @Sendable (String) async throws -> SendTransactionNetworkStatus
    init(executor: Executor? = nil,
         exactStatus: (@Sendable (String) async throws -> SendTransactionNetworkStatus)? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        self.executor = executor ?? { try await session.data(for: $0) }
        self.exactStatus = exactStatus ?? { try await SendBitcoinExactStatus().status(hash: $0) }
    }

    func conflict(chain: BitcoinFamilyChain, hash: String, originalRaw: String?) async throws -> PendingBitcoinConflict? {
        let endpoint = AdaptiveProviderEndpoint(serviceID: "pending-conflict.\(chain.networkID)",
            endpointURL: URL(string: "https://mempool.space")!, baselinePriority: 0)
        return try await ProviderRequestDeadline.run(seconds: 20, endpoint: endpoint) {
            try await readConflict(chain: chain, hash: hash, originalRaw: originalRaw)
        }
    }

    private func readConflict(chain: BitcoinFamilyChain, hash: String, originalRaw: String?) async throws -> PendingBitcoinConflict? {
        guard SendTransactionStatusValidation.isHexHash(hash, byteCount: 32, allowsPrefix: false) else {
            throw BitcoinFamilyElectrumError.invalidResponse
        }
        if chain == .bitcoin {
            // The replacement tree works even for transactions first observed
            // by older app builds which did not retain the original inputs.
            if let replacement = try? await rbfConflict(hash: hash) { return replacement }
            if let raw = originalRaw, let original = BitcoinRawTransaction(hex: raw), original.transactionID == hash {
                for input in original.inputs.prefix(64) {
                    try Task.checkCancellation()
                    let path = "tx/\(input.previousHash)/outspend/\(input.previousIndex)"
                    if let object = try await json(base: "https://mempool.space/api", path: path)?.object,
                       object["spent"]?.booleanValue == true, let other = object["txid"]?.string, other != hash,
                       SendTransactionStatusValidation.isHexHash(other, byteCount: 32, allowsPrefix: false),
                       let transaction = try await json(base: "https://mempool.space/api", path: "tx/\(other)"),
                       transaction.object?["txid"]?.string == other,
                       let conflict = try Self.verifiedConflict(original: original, candidate: transaction) {
                        return conflict
                    }
                }
            }
            return nil
        }
        guard let raw = originalRaw, let original = BitcoinRawTransaction(hex: raw), original.transactionID == hash else { return nil }
        let electrum = BitcoinFamilyElectrumClient.shared
        // One matching spent input is sufficient proof. Bound enrichment so an
        // adversarial large transaction cannot monopolize foreground monitoring.
        for input in original.inputs.prefix(8) {
            try Task.checkCancellation()
            let value = try await electrum.call(chain: chain, method: "blockchain.transaction.get",
                params: [AnyEncodable(input.previousHash), AnyEncodable(false)])
            guard let hex = value.string, let previous = BitcoinRawTransaction(hex: hex),
                  previous.transactionID == input.previousHash, previous.outputs.indices.contains(input.previousIndex) else { continue }
            let scriptHash = Data(SHA256.hash(data: previous.outputs[input.previousIndex].script)).reversed()
                .map { String(format: "%02x", $0) }.joined()
            let history = try await electrum.call(chain: chain, method: "blockchain.scripthash.get_history",
                params: [AnyEncodable(scriptHash)], maximumResponseBytes: BitcoinFamilyElectrumClient.maximumHistoryResponseBytes)
            guard let rows = history.array else { throw BitcoinFamilyElectrumError.invalidResponse }
            let candidates = rows.compactMap { row -> (String, Int64)? in
                guard let h = row.object?["tx_hash"]?.string, let height = row.object?["height"]?.exactInt64,
                      h != hash, h != input.previousHash,
                      SendTransactionStatusValidation.isHexHash(h, byteCount: 32, allowsPrefix: false) else { return nil }
                return (h, height)
            }.sorted { ($0.1 <= 0 ? Int64.max : $0.1) > ($1.1 <= 0 ? Int64.max : $1.1) }
            for (candidate, height) in candidates.prefix(16) {
                try Task.checkCancellation()
                let v = try await electrum.call(chain: chain, method: "blockchain.transaction.get",
                    params: [AnyEncodable(candidate), AnyEncodable(false)])
                guard let raw = v.string, let tx = BitcoinRawTransaction(hex: raw), tx.transactionID == candidate,
                      tx.inputs.contains(where: { $0.previousHash == input.previousHash && $0.previousIndex == input.previousIndex }) else { continue }
                let exact = try await electrum.transactionStatus(chain: chain, hash: candidate)
                guard exact == .pending || exact == .confirmed else { continue }
                return PendingBitcoinConflict(hash: candidate, confirmed: height > 0 && exact == .confirmed)
            }
        }
        return nil
    }

    static func verifiedConflict(original: BitcoinRawTransaction, candidate: JSONValue) throws -> PendingBitcoinConflict? {
        guard let object = candidate.object, let hash = object["txid"]?.string,
              hash != original.transactionID,
              SendTransactionStatusValidation.isHexHash(hash, byteCount: 32, allowsPrefix: false),
              let inputs = object["vin"]?.array, let status = object["status"]?.object,
              let confirmed = status["confirmed"]?.booleanValue else { throw BitcoinFamilyElectrumError.invalidResponse }
        guard inputs.contains(where: { vin in
            original.inputs.contains { $0.previousHash == vin.object?["txid"]?.string
                && Int64($0.previousIndex) == vin.object?["vout"]?.exactInt64 }
        }) else { return nil }
        if confirmed {
            guard (status["block_height"]?.exactInt64 ?? 0) > 0,
                  let block = status["block_hash"]?.string,
                  SendTransactionStatusValidation.isHexHash(block, byteCount: 32, allowsPrefix: false) else {
                throw BitcoinFamilyElectrumError.invalidResponse
            }
        }
        return PendingBitcoinConflict(hash: hash, confirmed: confirmed)
    }

    private func json(base: String, path: String) async throws -> JSONValue? {
        let (data, response) = try await executor(URLRequest(url: URL(string: base + "/" + path)!))
        guard let http = response as? HTTPURLResponse, data.count <= 2_000_000 else { throw BitcoinFamilyElectrumError.invalidResponse }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw BitcoinFamilyElectrumError.unavailable }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func rbfConflict(hash: String) async throws -> PendingBitcoinConflict? {
        guard let rbf = try await json(base: "https://mempool.space/api/v1", path: "tx/\(hash)/rbf"),
              let root = rbf.object?["replacements"], let replacement = root.object?["tx"]?.object?["txid"]?.string,
              replacement != hash,
              SendTransactionStatusValidation.isHexHash(replacement, byteCount: 32, allowsPrefix: false),
              Self.rbfContains(hash: hash, node: root, depth: 0) else { return nil }
        let status = try await exactStatus(replacement)
        guard status == .pending || status == .confirmed else { return nil }
        return PendingBitcoinConflict(hash: replacement, confirmed: status == .confirmed)
    }

    static func rbfContains(hash: String, node: JSONValue, depth: Int) -> Bool {
        guard depth < 32, let object = node.object else { return false }
        if object["tx"]?.object?["txid"]?.string == hash { return true }
        return object["replaces"]?.array?.contains { rbfContains(hash: hash, node: $0, depth: depth + 1) } == true
    }
}

private extension JSONValue {
    var booleanValue: Bool? { if case let .bool(value) = self { value } else { nil } }
}

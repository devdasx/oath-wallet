import Foundation
import OathDiagnostics

/// A complete callTracer result, bound to the receipt used to request it.
/// Gas is excluded: call values represent movements, not balance differences.
public struct EVMHistoryTrace: Codable, Sendable {
    public let chainID: UInt64
    public let transactionHash: String
    public let blockHash: String
    public let root: SolanaJSON

    public init(chainID: UInt64, transactionHash: String, blockHash: String, root: SolanaJSON) {
        self.chainID = chainID; self.transactionHash = transactionHash.lowercased()
        self.blockHash = blockHash.lowercased(); self.root = root
    }

    // History-only wrapped native identities from Uniswap's deployment parameters.
    // Extending recognition must not change the signing preview's accepted routes.
    static let wrappedNative = WalletConnectSwapReview.wrappedNative.merging([
        43114: "0xb31f66aa3c1e785363f0875a1b74e27b85fd66c7",
        143: "0x3bd359c1119da7da1d913d1c4d2b7c461115433a",
        999: "0x5555555555555555555555555555555555555555",
        4663: "0x0bd7d308f8e1639fab988df18a8011f41eacad73",
        196: "0xe538905cf8410324e03a5a23c1c177a474d59b2b",
    ]) { _, verified in verified }

    struct Transfer {
        let from: String, to: String, amount: String
    }
    struct Movement {
        var transfers: [Transfer] = []
        var credits = "0"
        var debits = "0"
    }

    func movements(transaction: SolanaJSON, receipt: SolanaJSON, owner: String, chainID: UInt64) throws -> Movement? {
        guard self.chainID == chainID, transactionHash == transaction["hash"].string?.lowercased(),
              transactionHash == receipt["transactionHash"].string?.lowercased(),
              blockHash == transaction["blockHash"].string?.lowercased(),
              blockHash == receipt["blockHash"].string?.lowercased(), receipt["status"].string == "0x1",
              root["type"].string == "CALL", root["error"].isNull,
              root["from"].string?.lowercased() == transaction["from"].string?.lowercased(),
              root["to"].string?.lowercased() == transaction["to"].string?.lowercased(),
              root["input"].string?.lowercased() == transaction["input"].string?.lowercased(),
              let value = root["value"].string, let expected = transaction["value"].string,
              try AnkrQuantity.decimal(value) == AnkrQuantity.decimal(expected) else { return nil }
        var remaining = 4096, movement = Movement()
        func visit(_ frame: SolanaJSON, depth: Int) throws -> Bool {
            guard depth <= 64, remaining > 0 else { return false }
            remaining -= 1
            // A reverted parent rolls back all child movements, even successful children.
            if !frame["error"].isNull { return true }
            guard let kind = frame["type"].string,
                  ["CALL", "STATICCALL", "DELEGATECALL", "CALLCODE", "CREATE", "CREATE2", "SELFDESTRUCT"].contains(kind),
                  let from = frame["from"].string, let to = frame["to"].string,
                  let source = try? EVMSendIdentity.address(from), let destination = try? EVMSendIdentity.address(to) else { return false }
            if ["CALL", "CREATE", "CREATE2", "SELFDESTRUCT"].contains(kind) {
                guard let raw = frame["value"].string else { return false }
                let amount = try EVMSendAmount.checked(AnkrQuantity.decimal(raw))
                if amount != "0" { movement.transfers.append(.init(from: source, to: destination, amount: amount)) }
                if source == owner { movement.debits = try EVMSendAmount.add(movement.debits, amount) }
                if destination == owner { movement.credits = try EVMSendAmount.add(movement.credits, amount) }
            }
            guard frame["calls"].isNull || frame["calls"].array != nil else { return false }
            for child in frame["calls"].array ?? [] {
                guard try visit(child, depth: depth + 1) else { return false }
            }
            return true
        }
        guard try visit(root, depth: 0) else { return nil }
        return movement
    }
}

extension EVMSendClient {
    /// Enrich only unresolved swap/bridge receipts. Providers without tracing
    /// retain receipt-based history; the RPC boundary already reports failures.
    public func historyExecutionEvidence(_ evidence: EVMHistoryEvidence) async throws -> EVMHistoryEvidence {
        guard let hash = evidence.transaction["hash"].string,
              let owner = evidence.transaction["from"].string,
              evidence.receipt["status"].string == "0x1",
              let logs = evidence.receipt["logs"].array,
              logs.contains(where: { log in
                  [EVMHistorySwap.v2Topic, EVMHistorySwap.v3Topic, EVMHistorySwap.pancakeV3Topic, EVMHistorySwap.v4Topic,
                   EVMHistoryBridge.deposited, EVMHistoryBridge.filled,
                   EVMHistoryBridge.relayDeposit, EVMHistoryBridge.relayExecution].contains(log["topics"].array?.first?.string ?? "")
              }) else { return evidence }
        if try EVMHistorySwap.classify(transaction: evidence.transaction, receipt: evidence.receipt,
                owner: owner, chainID: network.chainID, trace: evidence.trace, pools: evidence.pools ?? []) != nil { return evidence }
        async let trace = historyTrace(evidence, owner: owner)
        async let pools = historyPoolEvidence(evidence)
        let enriched = try await EVMHistoryEvidence(transaction: evidence.transaction, receipt: evidence.receipt, trace: trace, pools: pools)
        do {
            // Traces lack block identity. Recheck after tracing and historical
            // pool lookups so reorganized blocks cannot mix old/new evidence.
            let current = try await rpc("eth_getTransactionReceipt", [.string(hash)])
            return current == evidence.receipt ? enriched : evidence
        } catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            OathDiagnostics.record(error, component: "history_execution", operation: "receipt_recheck", context: ["chain": network.rawValue])
            return evidence
        }
    }
    private func historyTrace(_ evidence: EVMHistoryEvidence, owner: String) async throws -> EVMHistoryTrace? {
        if let trace = evidence.trace { return trace }
        guard let hash = evidence.transaction["hash"].string, let block = evidence.receipt["blockHash"].string else { return nil }
        do {
            let root = try await rpc("debug_traceTransaction", [.string(hash), .object([
                "tracer": .string("callTracer"), "timeout": .string("5s"),
                "tracerConfig": .object(["onlyTopCall": .bool(false)])])])
            let trace = EVMHistoryTrace(chainID: network.chainID, transactionHash: hash, blockHash: block, root: root)
            guard try trace.movements(transaction: evidence.transaction, receipt: evidence.receipt,
                                      owner: owner, chainID: network.chainID) != nil else {
                if !root.isNull { OathDiagnostics.record(EVMSendError.malformed, component: "history_execution", operation: "trace_validation", context: ["chain": network.rawValue]) }
                return nil
            }
            return trace
        } catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            OathDiagnostics.record(error, component: "history_execution", operation: "trace", context: ["chain": network.rawValue])
            return nil
        }
    }
}

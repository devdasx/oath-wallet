import Foundation
import OathDiagnostics

public struct CronosAccountBalances: Sendable {
    public let owner: String
    public let height: Int64
    public let blockHash: String
    public let observedAt: Date
    public let amounts: [String: String]
}

extension EVMSendClient {
    /// Refresh native CRO and explicitly tracked CRC-20s. This does not claim
    /// account-wide token discovery or historical-index coverage from an RPC.
    public func cronosAccountBalances(owner: String, tokens: [String: Int]) async throws -> CronosAccountBalances {
        guard network == .cronos || network == .cronosTestnet, tokens.count <= 1_000 else { throw EVMSendError.wrongNetwork }
        let owner = try EVMSendIdentity.address(owner)
        for (reference, decimals) in tokens {
            guard reference != "native", try EVMSendIdentity.address(reference) == reference,
                  (0...255).contains(decimals) else { throw EVMSendError.metadataChanged }
        }
        return try await OathDiagnostics.withChain(network.rawValue) {
            let head = try await rpc("eth_getBlockByNumber", [.string("latest"), .bool(false)], requireFreshHead: true)
            let height = try Self.uint(head["number"])
            guard height <= UInt64(Int64.max), let hash = head["hash"].string, AnkrQuantity.hash(hash) else { throw EVMSendError.malformed }
            let tag = SolanaJSON.string("0x" + String(height, radix: 16))
            async let native = balance(owner: owner, reference: "native", tag: tag)
            let entries = tokens.sorted { $0.key < $1.key }
            var amounts = await withTaskGroup(of: (String, String?).self) { group in
                var next = 0, values: [String: String] = [:]
                func enqueue() {
                    guard next < entries.count, !Task.isCancelled else { return }
                    let (reference, expectedDecimals) = entries[next]; next += 1
                    group.addTask {
                        let value = await OathDiagnostics.attempt("cronos_token_balance") {
                            async let metadata = self.decimals(reference, tag: tag)
                            async let amount = self.balance(owner: owner, reference: reference, tag: tag)
                            guard try await metadata == expectedDecimals else { throw EVMSendError.metadataChanged }
                            return try await amount
                        }
                        return (reference, value)
                    }
                }
                for _ in 0..<min(4, entries.count) { enqueue() }
                for await (reference, amount) in group { values[reference] = amount; enqueue() }
                return values
            }
            amounts["native"] = try await native
            try Task.checkCancellation()
            let check = try await rpc("eth_getBlockByNumber", [tag, .bool(false)])
            guard check["hash"].string == hash else { throw EVMSendError.changed }
            return .init(owner: owner, height: Int64(height), blockHash: hash, observedAt: .now, amounts: amounts)
        }
    }
}

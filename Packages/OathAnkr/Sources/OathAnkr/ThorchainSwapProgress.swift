import Foundation
import OathDiagnostics

/// Read-only THORNode observations. An outbound signature alone is NOT proof of
/// delivery. Only a matching observed outbound (or refund) advances the result.
public struct ThorchainSwapProgress: Sendable, Equatable {
    public let hash: String
    public let memo: ThorchainSwapMemo
    public let depositConfirmed: Bool
    public let swapFinalised: Bool
    public let outboundSigned: Bool
    public let refundPlanned: Bool
    public let outboundHash: String?
    public let refundHash: String?
    public let refundObserved: Bool
    public var isFinished: Bool { outboundHash != nil || refundObserved }

    public static func decode(_ json: SolanaJSON, hash: String, poolAssets: [String] = []) throws -> Self? {
        guard validHash(hash), json["error"].isNull, json["code"].isNull else { throw ThorchainError.malformed }
        let tx = json["tx"]
        // A missing indexed transaction or a different kind of protocol action
        // is not a failed swap. It must not produce invented progress.
        guard !tx.isNull else { return nil }
        guard tx["id"].string?.uppercased() == hash.uppercased() else { throw ThorchainError.wrongOwner }
        guard tx["chain"].string == "THOR", let source = tx["from_address"].string,
              let memo = tx["memo"].string.flatMap({ ThorchainSwapMemo($0, poolAssets: poolAssets) }),
              let coins = tx["coins"].array, coins.count == 1, coins[0]["asset"].string == "THOR.RUNE" else { return nil }
        _ = try ThorchainIdentity.address(source)
        guard try ThorchainIdentity.amount(coins[0]["amount"]) != "0" else { throw ThorchainError.malformed }
        let stages = json["stages"]
        func done(_ key: String) throws -> Bool {
            let value = stages[key]["completed"]
            if value.isNull { return false }
            guard case .bool(let b) = value else { throw ThorchainError.malformed }; return b
        }
        let deposit = try done("inbound_finalised"), swapped = try done("swap_finalised"), signed = try done("outbound_signed")
        guard let planned = json["planned_out_txs"].array ?? (json["planned_out_txs"].isNull ? [] : nil),
              let outbounds = json["out_txs"].array ?? (json["out_txs"].isNull ? [] : nil),
              planned.count <= 64, outbounds.count <= 64 else { throw ThorchainError.malformed }
        let refundPlanned = planned.contains { $0["refund"] == .bool(true) && $0["to_address"].string == source && $0["coin"]["asset"].string == "THOR.RUNE" }
        var output: String?, refund: String?
        var refundObserved = false
        let destinationChain = String(memo.asset.prefix(while: { $0 != "." }))
        for tx in outbounds {
            guard let id = tx["id"].string, (tx["chain"].string == "SOL" ? SolanaIdentity.isSignature(id) : validHash(id)),
                  let coins = tx["coins"].array, coins.count <= 64 else { continue }
            let positive = try coins.filter { try ThorchainIdentity.amount($0["amount"]) != "0" }
            let observedMemo = tx["memo"].string?.uppercased()
            if !id.allSatisfy({ $0 == "0" }), tx["chain"].string == destinationChain, sameDestination(tx["to_address"].string, memo.destination, chain: destinationChain),
               observedMemo == "OUT:" + hash.uppercased(), positive.contains(where: { $0["asset"].string == memo.asset }) {
                output = id
            }
            if tx["chain"].string == "THOR", tx["to_address"].string == source,
               observedMemo == "REFUND:" + hash.uppercased(), positive.contains(where: { $0["asset"].string == "THOR.RUNE" }) {
                refundObserved = true
                // Internal native transfers have the protocol's all-zero ID.
                // Report the observed refund without inventing a transaction hash.
                if !id.allSatisfy({ $0 == "0" }) { refund = id }
            }
        }
        // Contradictory provider data stays unknown, never becomes success.
        guard output == nil || (deposit && swapped && !refundObserved), !refundObserved || (deposit && output == nil) else { throw ThorchainError.malformed }
        return .init(hash: hash.uppercased(), memo: memo, depositConfirmed: deposit,
            swapFinalised: swapped, outboundSigned: signed, refundPlanned: refundPlanned, outboundHash: output, refundHash: refund, refundObserved: refundObserved)
    }
    private static func sameDestination(_ first: String?, _ second: String, chain: String) -> Bool {
        guard let first else { return false }
        return ThorchainSwapAsset.evmChains.values.contains(chain)
            ? first.lowercased() == second.lowercased() : first == second
    }
    private static func validHash(_ hash: String) -> Bool {
        hash.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
}

extension ThorchainClient {
    public func swapProgress(hash: String) async throws -> ThorchainSwapProgress? {
        guard hash.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw ThorchainError.malformed }
        return try await OathDiagnostics.$chain.withValue("thorchain") {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    let json = try await read(Self.node, path: "thorchain/tx/status/" + hash)
                    var memo: ThorchainSwapMemo?
                    if let raw = json["tx"]["memo"].string { memo = try await resolvedSwapMemo(raw) }
                    return try ThorchainSwapProgress.decode(json, hash: hash, poolAssets: memo.map { [$0.asset] } ?? [])
                }
                catch {
                    OathDiagnostics.record(error, component: "walletconnect", operation: "thorchain_swap_progress")
                    throw error
                }
            }
        }
    }
}

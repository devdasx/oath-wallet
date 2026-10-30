import Foundation
import CryptoKit

/// TON's original external-message multisig, as shipped by @ton/ton 16.3.0.
/// All approvals are collected locally before submission. No partial orders,
/// arbitrary messages, signer rotation, or contract upgrades are exposed.
public struct TonMultisigPolicy: Codable, Sendable, Equatable {
    public static let maximumKeys = 7
    public let required: Int
    public let publicKeys: [Data]
    public init(required: Int, publicKeys: [Data]) throws {
        guard (2...Self.maximumKeys).contains(publicKeys.count), (1...publicKeys.count).contains(required),
              publicKeys.allSatisfy({ $0.count == 32 }), Set(publicKeys).count == publicKeys.count else { throw TonSendError.wrongOwner }
        self.required = required; self.publicKeys = publicKeys.sorted { $0.lexicographicallyPrecedes($1) }
    }
    public func validate() throws {
        guard self == (try Self(required: required, publicKeys: publicKeys)) else { throw TonSendError.wrongOwner }
    }
    // Separate addresses on each network prevent cross-network signature replay.
    static func walletID(_ network: TonSendNetwork) -> UInt64 { network == .mainnet ? 0x4f415448 : 0xcf415448 }
    public func address(network: TonSendNetwork) throws -> String {
        try validate(); return "0:" + TronSendCrypto.hex(try stateInit(network).hash)
    }
    static func code() throws -> TonCell {
        guard let url = Bundle.module.url(forResource: "TonMultisigV1", withExtension: "b64"),
              let bytes = Data(base64Encoded: try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) else { throw TonSendError.configuration }
        let cell = try TonCell.parse(bytes)
        guard TronSendCrypto.hex(cell.hash) == "5a55840263d27945feb55b53fa85afa4f9dd61ea573e1eeba1ecac9c96581881" else { throw TonSendError.signing }
        return cell
    }
    func owners() throws -> TonCell {
        try TonMultisigDictionary.encode(publicKeys.enumerated().map { (UInt64($0.offset), $0.element + Data([0])) }, width: 8)
    }
    func stateInit(_ network: TonSendNetwork) throws -> TonCell {
        var d = TonBuilder(); try d.uint(Self.walletID(network), 32); try d.uint(UInt64(publicKeys.count), 8)
        try d.uint(UInt64(required), 8); try d.uint(0, 64); try d.uint(1, 1); try d.ref(owners()); try d.uint(0, 1)
        var s = TonBuilder(); try s.uint(6, 5); try s.ref(Self.code()); try s.ref(d.cell()); return try s.cell()
    }
    func validateState(code: TonCell?, data: TonCell?, network: TonSendNetwork) throws {
        try validate()
        guard code?.hash == (try Self.code().hash), let data else { throw TonSendError.wrongOwner }
        var d = TonReader(data)
        guard try d.uint(32) == Self.walletID(network), try d.uint(8) == publicKeys.count,
              try d.uint(8) == required else { throw TonSendError.wrongOwner }
        try d.skip(64)
        guard try d.uint(1) == 1 else { throw TonSendError.wrongOwner }
        let entries = try TonMultisigDictionary.decode(d.ref(), width: 8, limit: Self.maximumKeys)
        guard entries.count == publicKeys.count else { throw TonSendError.wrongOwner }
        for (i, key) in publicKeys.enumerated() {
            guard let entry = entries[UInt64(i)], entry.bits.count == 264, entry.refs.isEmpty,
                  Data(entry.padded.prefix(32)) == key else { throw TonSendError.wrongOwner }
        }
        if try d.uint(1) == 1 { _ = try d.ref() }
        guard d.offset == data.bits.count, d.refOffset == data.refs.count else { throw TonSendError.malformed }
    }
    /// Only an absent replay entry newer than last_cleaned proves that a query
    /// was never accepted. Processed or garbage-collected entries stay unknown
    /// until their trace is indexed; never release the spending lock on a guess.
    static func queryWasNeverAccepted(_ query: UInt64, data: TonCell) throws -> Bool {
        var r = TonReader(data); try r.skip(48)
        let lastCleaned = try r.uint(64)
        guard query > lastCleaned else { return false }
        guard try r.uint(1) == 1 else { throw TonSendError.malformed }
        _ = try r.ref()
        if try r.uint(1) == 0 { return true }
        return try TonMultisigDictionary.decode(r.ref(), width: 64, limit: 4096)[query] == nil
    }

}

/// Bounded TL-B Hashmap encoder/reader. Used for immutable owner identities and
/// replay-state checks; accepts equivalent labels, rejects duplicate/extra leaves.
enum TonMultisigDictionary {
    static func encode(_ entries: [(UInt64, Data)], width: Int) throws -> TonCell {
        guard !entries.isEmpty, width <= 8 else { throw TonSendError.malformed }
        func edge(_ values: [(UInt64, Data)], _ remaining: Int) throws -> TonCell {
            var prefix = 0
            while prefix < remaining {
                let bit = (values[0].0 >> (remaining - prefix - 1)) & 1
                if !values.allSatisfy({ ($0.0 >> (remaining - prefix - 1)) & 1 == bit }) { break }; prefix += 1
            }
            let w = remaining == 0 ? 0 : Int(floor(log2(Double(remaining)))) + 1
            let label = prefix == 0 ? 0 : (values[0].0 >> (remaining - prefix)) & ((1 << prefix) - 1)
            let short = 2 + 2 * prefix, long = 2 + w + prefix, same = 3 + w
            var b = TonBuilder()
            if (label == 0 || label == (1 << prefix) - 1), same < min(short, long) {
                try b.uint(3, 2); try b.uint(label == 0 ? 0 : 1, 1); try b.uint(UInt64(prefix), w)
            } else if long < short {
                try b.uint(2, 2); try b.uint(UInt64(prefix), w); try b.uint(label, prefix)
            } else {
                try b.uint(0, 1); for _ in 0..<prefix { try b.uint(1, 1) }; try b.uint(0, 1); try b.uint(label, prefix)
            }
            if prefix == remaining { guard values.count == 1 else { throw TonSendError.malformed }; try b.bytes(values[0].1) }
            else {
                let bit = remaining - prefix - 1
                try b.ref(edge(values.filter { ($0.0 >> bit) & 1 == 0 }, bit))
                try b.ref(edge(values.filter { ($0.0 >> bit) & 1 == 1 }, bit))
            }
            return try b.cell()
        }
        return try edge(entries, width)
    }
    static func decode(_ root: TonCell, width: Int, limit: Int) throws -> [UInt64: TonCell] {
        var out = [UInt64: TonCell]()
        func edge(_ c: TonCell, _ remaining: Int, _ prefix: UInt64) throws {
            guard remaining >= 0, remaining <= 64 else { throw TonSendError.malformed }
            var r = TonReader(c); var n = 0; var label: UInt64 = 0
            let w = remaining == 0 ? 0 : Int(floor(log2(Double(remaining)))) + 1
            if try r.uint(1) == 0 {
                while try r.uint(1) == 1 { n += 1; guard n <= remaining else { throw TonSendError.malformed } }
                label = try r.uint(n)
            } else if try r.uint(1) == 0 { n = Int(try r.uint(w)); guard n <= remaining else { throw TonSendError.malformed }; label = try r.uint(n) }
            else {
                let bit = try r.uint(1); n = Int(try r.uint(w)); guard n <= remaining else { throw TonSendError.malformed }
                label = bit == 0 ? 0 : n == 64 ? UInt64.max : (1 << n) - 1
            }
            let p = n == 64 ? label : (prefix << n) | label
            if n == remaining {
                guard out.count < limit, out[p] == nil else { throw TonSendError.malformed }
                out[p] = try TonCell(Array(c.bits.dropFirst(r.offset)), Array(c.refs.dropFirst(r.refOffset)))
            } else {
                guard r.offset == c.bits.count, c.refs.count == 2 else { throw TonSendError.malformed }
                try edge(r.ref(), remaining - n - 1, p << 1); try edge(r.ref(), remaining - n - 1, (p << 1) | 1)
            }
        }
        try edge(root, width, 0); return out
    }
}

public enum TonMultisigCrypto {
    struct Approval: Codable { let index: Int; let signature: Data }
    struct Envelope: Codable { let root: Int; let signature: Data; let approvals: [Approval] }
    static func payload(_ p: TonSendPlan) throws -> TonCell {
        var b = TonBuilder(); try b.uint(TonMultisigPolicy.walletID(p.network), 32)
        try b.uint(p.queryID, 64); try b.uint(3, 8); try b.ref(TonSendCrypto.internalMessage(p)); return try b.cell()
    }
    static func rootCell(_ p: TonSendPlan, _ e: Envelope) throws -> TonCell {
        var list = TonBuilder(); try list.uint(0, 1)
        for a in e.approvals {
            var node = TonBuilder(); try node.bytes(a.signature); try node.uint(UInt64(a.index), 8); try node.inline(list.cell())
            list = TonBuilder(); try list.uint(1, 1); try list.ref(node.cell())
        }
        var b = TonBuilder(); try b.uint(UInt64(e.root), 8); try b.inline(list.cell()); try b.inline(payload(p)); return try b.cell()
    }
    static func body(_ p: TonSendPlan, _ e: Envelope) throws -> TonCell {
        var b = TonBuilder(); try b.bytes(e.signature); try b.inline(rootCell(p, e)); return try b.cell()
    }
    static func zeroEnvelope(_ p: TonSendPlan) throws -> Envelope {
        guard let policy = p.multisig else { throw TonSendError.signing }
        return .init(root: 0, signature: Data(repeating: 0, count: 64), approvals: (1..<policy.required).map { .init(index: $0, signature: Data(repeating: 0, count: 64)) })
    }
    public static func sign(_ plan: TonSendPlan, privateKeys: [Data], now: Date = .now) throws -> TonSignedSend {
        try plan.validate(now: now)
        guard let policy = plan.multisig, privateKeys.count >= policy.required, privateKeys.count <= policy.publicKeys.count else { throw TonSendError.signing }
        let keys = try privateKeys.map { try Curve25519.Signing.PrivateKey(rawRepresentation: $0) }
        let pubs = keys.map { $0.publicKey.rawRepresentation }
        guard Set(pubs).count == pubs.count, pubs.allSatisfy({ policy.publicKeys.contains($0) }) else { throw TonSendError.signing }
        let selected = keys.sorted { $0.publicKey.rawRepresentation.lexicographicallyPrecedes($1.publicKey.rawRepresentation) }.prefix(policy.required)
        let root = selected.first!, rootIndex = policy.publicKeys.firstIndex(of: root.publicKey.rawRepresentation)!
        let hash = try payload(plan).hash
        let approvals = try selected.dropFirst().map { key in
            Approval(index: policy.publicKeys.firstIndex(of: key.publicKey.rawRepresentation)!, signature: try key.signature(for: hash))
        }
        let unsigned = Envelope(root: rootIndex, signature: Data(), approvals: approvals)
        let e = Envelope(root: rootIndex, signature: try root.signature(for: rootCell(plan, unsigned).hash), approvals: approvals)
        let body = try body(plan, e)
        return .init(bytes: try TonSendCrypto.external(plan, body).boc(), signature: try JSONEncoder().encode(e),
                     hash: TronSendCrypto.hex(try TonSendCrypto.external(plan, body, normalized: true).hash), bodyHash: TronSendCrypto.hex(body.hash))
    }
    static func verifiedBody(_ signed: TonSignedSend, _ plan: TonSendPlan) throws -> TonCell {
        guard let policy = plan.multisig, signed.signature.count <= 8192 else { throw TonSendError.signing }
        let e = try JSONDecoder().decode(Envelope.self, from: signed.signature)
        let indices = [e.root] + e.approvals.map(\.index)
        guard indices.count == policy.required, Set(indices).count == indices.count,
              indices.allSatisfy({ policy.publicKeys.indices.contains($0) }), e.signature.count == 64,
              e.approvals.allSatisfy({ $0.signature.count == 64 }), e.approvals.map(\.index) == e.approvals.map(\.index).sorted() else { throw TonSendError.signing }
        for a in e.approvals {
            guard try Curve25519.Signing.PublicKey(rawRepresentation: policy.publicKeys[a.index]).isValidSignature(a.signature, for: payload(plan).hash) else { throw TonSendError.signing }
        }
        guard try Curve25519.Signing.PublicKey(rawRepresentation: policy.publicKeys[e.root]).isValidSignature(e.signature, for: rootCell(plan, e).hash) else { throw TonSendError.signing }
        return try body(plan, e)
    }
}

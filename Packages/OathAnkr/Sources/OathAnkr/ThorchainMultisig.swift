import Foundation
import CryptoKit
import OathSecp256k1

/// Native Cosmos LegacyAminoPubKey, with the same address ordering as thornode.
/// The threshold is enforced by THORNode; no contract or privileged bootstrap key.
public struct ThorchainMultisigPolicy: Codable, Equatable, Sendable {
    // Mainnet and THORNode auth params cap total constituent keys at seven.
    public static let maximumKeys = 7
    public let required: Int
    public let publicKeys: [Data]
    private static func addressBytes(_ key: Data) -> Data { XrplRIPEMD160.hash(Data(SHA256.hash(data: key))) }
    private static func ordered(_ keys: [Data]) -> [Data] {
        keys.sorted { addressBytes($0).lexicographicallyPrecedes(addressBytes($1)) }
    }
    public init(required: Int, publicKeys: [Data]) throws {
        self.required = required; self.publicKeys = Self.ordered(publicKeys)
        try validate()
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        required = try c.decode(Int.self, forKey: .required)
        publicKeys = try c.decode([Data].self, forKey: .publicKeys)
        try validate()
    }
    public func validate() throws {
        guard (2...Self.maximumKeys).contains(publicKeys.count), (1...publicKeys.count).contains(required),
              publicKeys.allSatisfy({ $0.count == 33 && [2,3].contains($0.first!) }),
              Set(publicKeys).count == publicKeys.count, Self.ordered(publicKeys) == publicKeys else { throw ThorchainSendError.signing }
    }
    public var aminoPublicKey: Data {
        Data([0x22,0xc1,0xf7,0xe2]) + TronSendCrypto.number(1, UInt64(required))
            + publicKeys.reduce(Data()) { $0 + TronSendCrypto.field(2, Data([0xeb,0x5a,0xe9,0x87,0x21]) + $1) }
    }
    public func address(network: ThorchainSendNetwork) -> String {
        ThorchainSendCrypto.bech32(Data(SHA256.hash(data: aminoPublicKey).prefix(20)), prefix: network.prefix)
    }
    var protobufKey: Data {
        let keys = publicKeys.reduce(Data()) {
            $0 + TronSendCrypto.field(2, Self.any("/cosmos.crypto.secp256k1.PubKey", TronSendCrypto.field(1, $1)))
        }
        return Self.any("/cosmos.crypto.multisig.LegacyAminoPubKey", TronSendCrypto.number(1, UInt64(required)) + keys)
    }
    private static func any(_ type: String, _ bytes: Data) -> Data {
        TronSendCrypto.field(1, Data(type.utf8)) + TronSendCrypto.field(2, bytes)
    }
}

public extension ThorchainSendCrypto {
    static func multisigSignDoc(_ p: ThorchainSendPlan) throws -> Data {
        guard p.multisig != nil else { throw ThorchainSendError.signing }
        let doc: SolanaJSON = .object([
            "account_number": .string(String(p.accountNumber)), "chain_id": .string(p.network.chainID),
            "sequence": .string(String(p.sequence)), "timeout_height": .string(String(p.timeoutHeight)),
            "fee": .object(["amount": .array([]), "gas": .string(String(ThorchainSendPlan.gasLimit))]),
            "memo": .string(p.memo), "msgs": .array([.object([
                "type": .string("thorchain/MsgSend"), "value": .object([
                    "from_address": .string(p.sender), "to_address": .string(p.recipient),
                    "amount": .array([.object(["denom": .string(p.denom), "amount": .string(p.amount)])])])])])])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = String(decoding: try encoder.encode(doc), as: UTF8.self)
            .replacingOccurrences(of: "&", with: "\\u0026").replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return Data(text.utf8)
    }
    static func sign(_ plan: ThorchainSendPlan, privateKeys: [Data], now: Date = .now) throws -> ThorchainSignedSend {
        try plan.validate(now: now)
        guard let policy = plan.multisig, privateKeys.count >= policy.required, privateKeys.count <= policy.publicKeys.count else { throw ThorchainSendError.signing }
        let digest = Data(SHA256.hash(data: try multisigSignDoc(plan)))
        let parts = try privateKeys.map { key -> (Int,Data) in
            try Task.checkCancellation()
            guard let index = policy.publicKeys.firstIndex(of: try publicKey(privateKey: key)) else { throw ThorchainSendError.wrongOwner }
            return (index, try OathSecp256k1.signRecoverable(digest, key: key))
        }.sorted { $0.0 < $1.0 }
        guard Set(parts.map(\.0)).count == parts.count else { throw ThorchainSendError.signing }
        // Private journal envelope preserves indices and recovery IDs. Neither
        // this envelope nor raw signed bytes are diagnostics or public metadata.
        let envelope = Data([1, UInt8(parts.count)]) + parts.reduce(Data()) { $0 + Data([UInt8($1.0)]) + $1.1 }
        let bytes = try multisigBytes(plan, parts: parts)
        let signed = ThorchainSignedSend(bytes: bytes, signature: envelope,
            hash: TronSendCrypto.hex(Data(SHA256.hash(data: bytes))).uppercased())
        try verify(signed, plan: plan)
        return signed
    }
}
extension ThorchainSendCrypto {
    private static func multisigBytes(_ plan: ThorchainSendPlan, parts: [(Int,Data)]) throws -> Data {
        guard let policy = plan.multisig else { throw ThorchainSendError.signing }
        var bits = [UInt8](repeating: 0, count: (policy.publicKeys.count + 7) / 8)
        for (index, _) in parts { bits[index / 8] |= 1 << (7 - index % 8) }
        // Cosmos CompactBitArray uses zero when the last byte is full.
        let extra = policy.publicKeys.count % 8
        let bitArray = TronSendCrypto.number(1, UInt64(extra)) + TronSendCrypto.field(2, Data(bits))
        let single = TronSendCrypto.field(1, TronSendCrypto.number(1, 127))
        let multi = TronSendCrypto.field(1, bitArray) + parts.reduce(Data()) { a, _ in a + TronSendCrypto.field(2, single) }
        let signer = TronSendCrypto.field(1, policy.protobufKey) + TronSendCrypto.field(2, TronSendCrypto.field(2, multi)) + TronSendCrypto.number(3, plan.sequence)
        let auth = TronSendCrypto.field(1, signer) + TronSendCrypto.field(2, TronSendCrypto.number(2, ThorchainSendPlan.gasLimit))
        let signatures = parts.reduce(Data()) { $0 + TronSendCrypto.field(1, Data($1.1.prefix(64))) }
        return try TronSendCrypto.field(1, body(plan)) + TronSendCrypto.field(2, auth) + TronSendCrypto.field(3, signatures)
    }
    static func verifyMultisig(_ signed: ThorchainSignedSend, plan: ThorchainSendPlan) throws {
        guard let policy = plan.multisig, signed.signature.count >= 2 else { throw ThorchainSendError.signing }
        let data = Array(signed.signature), count = Int(data[1])
        guard data[0] == 1, count >= policy.required, count <= policy.publicKeys.count, data.count == 2 + 66 * count else { throw ThorchainSendError.signing }
        let digest = Data(SHA256.hash(data: try multisigSignDoc(plan)))
        var parts = [(Int,Data)](), last = -1
        for n in 0..<count {
            let start = 2 + n * 66, index = Int(data[start])
            guard index > last, index < policy.publicKeys.count else { throw ThorchainSendError.signing }
            let sig = Data(data[(start+1)..<(start+66)])
            let recovered = try OathSecp256k1.recover(sig, digest: digest)
            let compressed = Data([recovered.last! & 1 == 0 ? 2 : 3]) + recovered.dropFirst().prefix(32)
            guard compressed == policy.publicKeys[index] else { throw ThorchainSendError.signing }
            parts.append((index,sig)); last = index
        }
        guard signed.bytes == (try multisigBytes(plan, parts: parts)),
              signed.hash == TronSendCrypto.hex(Data(SHA256.hash(data: signed.bytes))).uppercased() else { throw ThorchainSendError.signing }
    }
}

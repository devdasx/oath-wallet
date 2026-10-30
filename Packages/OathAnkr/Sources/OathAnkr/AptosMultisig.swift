import Foundation
import CryptoKit

/// Native MultiKey authentication, restricted to locally recoverable Ed25519 keys.
/// Key ordering is canonical and part of the immutable account address.
public struct AptosMultisigPolicy: Codable, Equatable, Sendable {
    public static let maximumKeys = 32
    public let required: Int
    public let publicKeys: [Data]
    public init(required: Int, publicKeys: [Data]) throws {
        self.required = required
        self.publicKeys = publicKeys.sorted { $0.lexicographicallyPrecedes($1) }
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
              publicKeys.allSatisfy({ $0.count == 32 }), Set(publicKeys).count == publicKeys.count,
              publicKeys == publicKeys.sorted(by: { $0.lexicographicallyPrecedes($1) }) else { throw AptosSendError.signing }
    }
    public var bytes: Data {
        AptosBCS.uleb(publicKeys.count) + publicKeys.reduce(Data()) { $0 + Data([0]) + AptosBCS.vector($1) } + Data([UInt8(required)])
    }
    public var address: String { "0x" + TronSendCrypto.hex(TronSendCrypto.sha3(bytes + Data([3]))) }
}
public struct AptosMultisigSignature: Codable, Equatable, Sendable {
    public let index: Int
    public let signature: Data
    public init(index: Int, signature: Data) { self.index = index; self.signature = signature }
}
public extension AptosSendCrypto {
    static func sign(_ plan: AptosSendPlan, privateKeys: [Data], now: Date = .now) throws -> AptosSignedSend {
        try plan.validate(now: now)
        guard let policy = plan.multisig, privateKeys.count == policy.required else { throw AptosSendError.signing }
        let raw = try raw(plan), message = signingMessage(raw)
        let signatures = try privateKeys.map { bytes -> AptosMultisigSignature in
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
            guard let index = policy.publicKeys.firstIndex(of: key.publicKey.rawRepresentation) else { throw AptosSendError.signing }
            return try .init(index: index, signature: key.signature(for: message))
        }.sorted { $0.index < $1.index }
        guard Set(signatures.map(\.index)).count == signatures.count else { throw AptosSendError.signing }
        let bytes = raw + multisigAuthenticator(policy, signatures: signatures)
        let signed = AptosSignedSend(bytes: bytes, publicKey: policy.bytes, signature: Data(), hash: hash(bytes), signatures: signatures)
        try verify(signed, plan: plan)
        return signed
    }
    static func verifyMultisig(_ signed: AptosSignedSend, plan: AptosSendPlan) throws {
        guard let policy = plan.multisig, let signatures = signed.signatures,
              signed.publicKey == policy.bytes, signed.signature.isEmpty,
              signatures.count == policy.required, Set(signatures.map(\.index)).count == signatures.count,
              signatures.map(\.index) == signatures.map(\.index).sorted(),
              signatures.allSatisfy({ policy.publicKeys.indices.contains($0.index) && $0.signature.count == 64 }) else { throw AptosSendError.signing }
        let raw = try raw(plan)
        guard signed.bytes == raw + multisigAuthenticator(policy, signatures: signatures), signed.hash == hash(signed.bytes) else { throw AptosSendError.signing }
        for signature in signatures {
            guard try Curve25519.Signing.PublicKey(rawRepresentation: policy.publicKeys[signature.index])
                .isValidSignature(signature.signature, for: signingMessage(raw)) else { throw AptosSendError.signing }
        }
    }
}
extension AptosSendCrypto {
    static func multisigAuthenticator(_ policy: AptosMultisigPolicy, signatures: [AptosMultisigSignature]) -> Data {
        var bitmap = [UInt8](repeating: 0, count: 4)
        for signature in signatures { bitmap[signature.index / 8] |= 0x80 >> (signature.index % 8) }
        // TransactionAuthenticator::SingleSender(AccountAuthenticator::MultiKey).
        return Data([4, 3]) + policy.bytes + AptosBCS.uleb(signatures.count)
            + signatures.reduce(Data()) { $0 + Data([0]) + AptosBCS.vector($1.signature) } + AptosBCS.vector(Data(bitmap))
    }
    static func simulationAuthenticator(_ plan: AptosSendPlan) -> Data {
        if let policy = plan.multisig {
            return multisigAuthenticator(policy, signatures: (0..<policy.required).map { .init(index: $0, signature: Data(repeating: 0, count: 64)) })
        }
        return authenticator(publicKey: plan.publicKey, signature: Data(repeating: 0, count: 64))
    }
    static func verifyMultisigResponse(_ auth: AptosJSON, signed: AptosSignedSend, policy: AptosMultisigPolicy) throws {
        guard ["single_sender", "multi_key_signature"].contains(auth["type"].string ?? ""),
              auth["signatures_required"].integer == UInt64(policy.required),
              let keys = auth["public_keys"].array, keys.count == policy.publicKeys.count,
              let rows = auth["signatures"].array, let signatures = signed.signatures, rows.count == signatures.count else { throw AptosSendError.signing }
        for (index, key) in keys.enumerated() {
            guard key["type"].string == "ed25519", let value = key["value"].string,
                  try TronIdentity.hex(value) == policy.publicKeys[index] else { throw AptosSendError.signing }
        }
        for (row, signature) in zip(rows, signatures) {
            guard row["index"].integer == UInt64(signature.index), row["signature"]["type"].string == "ed25519",
                  let value = row["signature"]["value"].string, try TronIdentity.hex(value) == signature.signature else { throw AptosSendError.signing }
        }
    }
}

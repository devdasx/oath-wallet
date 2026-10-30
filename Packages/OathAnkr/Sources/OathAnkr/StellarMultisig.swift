import Foundation
import CryptoKit

/// Native equal-weight Stellar account policy. The bootstrap master is disabled
/// after all signers are installed in the same atomic transaction.
public struct StellarMultisigPolicy: Codable, Equatable, Sendable {
    public static let maximumKeys = 20
    public let account: String
    public let required: Int
    public let signers: [String]
    public init(account: String, required: Int, signers: [String]) throws {
        self.account = account; self.required = required; self.signers = signers.sorted()
        try validate()
    }
    public func validate() throws {
        guard (2...Self.maximumKeys).contains(signers.count), (1...signers.count).contains(required),
              Set(signers).count == signers.count, !signers.contains(account), signers == signers.sorted(),
              try StellarIdentity.address(account) == account else { throw StellarSendError.signing }
        for signer in signers { guard try StellarIdentity.address(signer) == signer else { throw StellarSendError.signing } }
    }
    func matches(_ value: StellarJSON) -> Bool {
        guard value["account_id"].string == account,
              let rows = value["signers"].array else { return false }
        for level in ["low_threshold", "med_threshold", "high_threshold"] {
            guard value["thresholds"][level].integer == UInt64(required) else { return false }
        }
        let active = rows.filter { $0["weight"].integer != 0 }
        return Set(active.compactMap { $0["key"].string }) == Set(signers) && active.count == signers.count && active.allSatisfy {
            $0["type"].string == "ed25519_public_key" && $0["weight"].integer == 1
                && signers.contains($0["key"].string ?? "")
        } && rows.contains { $0["key"].string == account && $0["weight"].integer == 0 }
    }
    func bootstrapMatches(_ value: StellarJSON) -> Bool {
        guard value["account_id"].string == account, let rows = value["signers"].array,
              rows.count == 1, rows[0]["key"].string == account,
              rows[0]["type"].string == "ed25519_public_key", rows[0]["weight"].integer == 1 else { return false }
        return ["low_threshold", "med_threshold", "high_threshold"].allSatisfy { value["thresholds"][$0].integer == 0 }
    }
}

public struct StellarMultisigSignature: Codable, Equatable, Sendable {
    public let publicKey: Data, signature: Data
    public init(publicKey: Data, signature: Data) { self.publicKey = publicKey; self.signature = signature }
}
public extension StellarSendCrypto {
    static func sign(_ plan: StellarSendPlan, privateKeys: [Data], now: Date = .now) throws -> StellarSignedSend {
        try plan.validate(now: now)
        guard let policy = plan.multisig, plan.kind != .configureMultisig,
              privateKeys.count == policy.required,
              plan.kind != .contract || plan.sorobanData != nil else { throw StellarSendError.signing }
        let tx = try StellarSendXDR.transaction(plan), hash = digest(tx, network: plan.network)
        let signatures = try privateKeys.map { bytes -> StellarMultisigSignature in
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
            return try .init(publicKey: key.publicKey.rawRepresentation, signature: key.signature(for: hash))
        }.sorted { $0.publicKey.lexicographicallyPrecedes($1.publicKey) }
        let signed = StellarSignedSend(bytes: StellarSendXDR.envelope(tx, signatures: signatures), publicKey: Data(), signature: Data(), hash: hex(hash), signatures: signatures)
        try verify(signed, plan: plan)
        return signed
    }
    static func verifyMultisig(_ signed: StellarSignedSend, plan: StellarSendPlan) throws {
        guard let policy = plan.multisig, let signatures = signed.signatures,
              signed.publicKey.isEmpty, signed.signature.isEmpty,
              signatures.count == policy.required,
              Set(signatures.map(\.publicKey)).count == signatures.count,
              signatures.map(\.publicKey) == signatures.map(\.publicKey).sorted(by: { $0.lexicographicallyPrecedes($1) }),
              plan.kind != .contract || plan.sorobanData != nil else { throw StellarSendError.signing }
        let tx = try StellarSendXDR.transaction(plan), hash = digest(tx, network: plan.network)
        guard signed.hash == hex(hash), signed.bytes == StellarSendXDR.envelope(tx, signatures: signatures) else { throw StellarSendError.signing }
        for item in signatures {
            guard item.publicKey.count == 32, item.signature.count == 64,
                  policy.signers.contains(StellarIdentity.encode(Array(item.publicKey), version: 48)),
                  try Curve25519.Signing.PublicKey(rawRepresentation: item.publicKey).isValidSignature(item.signature, for: hash) else { throw StellarSendError.signing }
        }
    }
}
extension StellarSendXDR {
    static func envelope(_ transaction: Data, signatures: [StellarMultisigSignature]) -> Data {
        u32(2) + transaction + u32(UInt32(signatures.count)) + signatures.reduce(Data()) { $0 + $1.publicKey.suffix(4) + opaque($1.signature) }
    }
    static func configure(_ policy: StellarMultisigPolicy) throws -> Data {
        var data = u32(UInt32(policy.signers.count + 1))
        for signer in policy.signers {
            // No source override; SetOptions, 8 absent options, signer present.
            data += u32(0) + u32(5) + Data(repeating: 0, count: 32) + u32(1)
            data += try account(signer) + u32(1)
        }
        // Last operation disables master and sets all three thresholds together.
        data += u32(0) + u32(5) + Data(repeating: 0, count: 12)
        data += u32(1) + u32(0)
        for _ in 0..<3 { data += u32(1) + u32(UInt32(policy.required)) }
        data += u32(0) + u32(0)
        return data
    }
}

public struct StellarMultisigState: Sendable {
    public let configured: Bool, balance: UInt64, reserve: UInt64
    public init(configured: Bool, balance: UInt64, reserve: UInt64) { self.configured = configured; self.balance = balance; self.reserve = reserve }
}

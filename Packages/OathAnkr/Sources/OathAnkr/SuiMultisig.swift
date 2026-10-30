import Foundation
import CryptoKit

/// Native Sui multisig with equal-weight Ed25519 members. Canonical ordering is
/// retained in recovery material because it is part of the account identity.
public struct SuiMultisigPolicy: Codable, Equatable, Sendable {
    public static let maximumKeys = 10
    public let required: Int
    public let publicKeys: [Data]
    public init(required: Int, publicKeys: [Data]) throws {
        self.required = required; self.publicKeys = publicKeys.sorted { $0.lexicographicallyPrecedes($1) }
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
              publicKeys == publicKeys.sorted(by: { $0.lexicographicallyPrecedes($1) }) else { throw SuiSendError.signing }
    }
    var members: Data { publicKeys.reduce(Data()) { $0 + Data([0]) + $1 + Data([1]) } }
    var bytes: Data { SuiBCS.length(publicKeys.count) + members + SuiBCS.u16(required) }
    public var address: String {
        "0x" + TronSendCrypto.hex(SuiSendCrypto.hash(Data([3]) + SuiBCS.u16(required) + members))
    }
}
public extension SuiSendCrypto {
    static func publicKey(privateKey: Data) throws -> Data {
        try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey).publicKey.rawRepresentation
    }
    static func sign(_ plan: SuiSendPlan, privateKeys: [Data], now: Date = .now) throws -> SuiSignedSend {
        try plan.validate(now: now)
        guard let policy = plan.multisig, privateKeys.count == policy.required else { throw SuiSendError.signing }
        let bytes = try plan.transactionBytes(), message = hash(Data([0, 0, 0]) + bytes)
        let signatures = try privateKeys.map { bytes -> (Int, Data) in
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
            guard let index = policy.publicKeys.firstIndex(of: key.publicKey.rawRepresentation) else { throw SuiSendError.signing }
            return (index, try key.signature(for: message))
        }.sorted { $0.0 < $1.0 }
        guard Set(signatures.map(\.0)).count == signatures.count else { throw SuiSendError.signing }
        let bitmap = signatures.reduce(0) { $0 | (1 << $1.0) }
        let envelope = Data([3]) + SuiBCS.list(signatures.map { Data([0]) + $0.1 }) + SuiBCS.u16(bitmap) + policy.bytes
        let signed = SuiSignedSend(bytes: bytes, signature: envelope, digest: digest(bytes))
        try verify(signed, sender: plan.sender)
        return signed
    }
}
extension SuiSendCrypto {
    static func verifyMultisig(_ signed: SuiSignedSend, sender: String) throws {
        // All vectors are <= 10, so their canonical ULEB length is one byte.
        let data = Array(signed.signature); var offset = 1
        func take(_ count: Int) throws -> Data {
            guard count >= 0, offset + count <= data.count else { throw SuiSendError.signing }
            defer { offset += count }; return Data(data[offset..<offset+count])
        }
        func byte() throws -> Int { Int(try take(1).first!) }
        func u16() throws -> Int { let b = Array(try take(2)); return Int(b[0]) | Int(b[1]) << 8 }
        guard data.count <= 1100, data.first == 3, signed.digest == digest(signed.bytes) else { throw SuiSendError.signing }
        let count = try byte(); guard (1...10).contains(count) else { throw SuiSendError.signing }
        var signatures = [Data]()
        for _ in 0..<count { guard try byte() == 0 else { throw SuiSendError.signing }; signatures.append(try take(64)) }
        let bitmap = try u16(), members = try byte()
        guard (2...10).contains(members), bitmap >> members == 0, bitmap.nonzeroBitCount == count else { throw SuiSendError.signing }
        var keys = [Data]()
        for _ in 0..<members {
            guard try byte() == 0 else { throw SuiSendError.signing }; keys.append(try take(32))
            guard try byte() == 1 else { throw SuiSendError.signing }
        }
        let required = try u16(), policy = try SuiMultisigPolicy(required: required, publicKeys: keys)
        guard offset == data.count, keys == policy.publicKeys, count == required, policy.address == sender else { throw SuiSendError.signing }
        var index = 0
        for i in keys.indices where bitmap & (1 << i) != 0 {
            guard try Curve25519.Signing.PublicKey(rawRepresentation: keys[i]).isValidSignature(signatures[index], for: hash(Data([0,0,0]) + signed.bytes)) else { throw SuiSendError.signing }
            index += 1
        }
    }
}

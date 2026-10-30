import Foundation
import CryptoKit

/// Squads v4 autonomous vault, fixed policy with no unilateral config authority.
public struct SolanaMultisigPolicy: Codable, Equatable, Sendable {
    public static let program = "SQDS4ep65T869zMMBKyuUq6aD6EgTu8psMjkvj52pCf"
    public static let maximumKeys = 5
    public let version: Int
    public let createKey: String
    public let required: Int
    public let members: [String]
    public init(createKey: String, required: Int, members: [String]) throws {
        self.version = 1; self.createKey = createKey; self.required = required
        self.members = members.sorted()
        try validate()
    }
    public func validate() throws {
        guard version == 1, SolanaIdentity.isAddress(createKey), (2...Self.maximumKeys).contains(members.count),
              (1...members.count).contains(required), Set(members).count == members.count,
              members == members.sorted(), members.allSatisfy(SolanaIdentity.isAddress), !members.contains(createKey) else { throw SolanaSendError.wrongOwner }
    }
    public var multisig: String { get throws { try Self.pda([Data("multisig".utf8), Data("multisig".utf8), SolanaSendCrypto.decode(createKey)]).0 } }
    public var vault: String { get throws { try Self.pda([Data("multisig".utf8), SolanaSendCrypto.decode(multisig), Data("vault".utf8), Data([0])]).0 } }
    /// Legacy/default payer only. New quotes choose a member from live balances.
    public var payer: String { members[0] }
    public func transaction(_ index: UInt64) throws -> String {
        try Self.pda([Data("multisig".utf8), SolanaSendCrypto.decode(multisig), Data("transaction".utf8), SolanaSendCrypto.le(index)]).0
    }
    public func proposal(_ index: UInt64) throws -> String {
        try Self.pda([Data("multisig".utf8), SolanaSendCrypto.decode(multisig), Data("transaction".utf8), SolanaSendCrypto.le(index), Data("proposal".utf8)]).0
    }
    public static var programConfig: String { get throws { try pda([Data("multisig".utf8), Data("program_config".utf8)]).0 } }
    static func pda(_ seeds: [Data]) throws -> (String, UInt8) {
        guard seeds.count < 16, seeds.allSatisfy({ $0.count <= 32 }) else { throw SolanaSendError.malformed }
        let seed = seeds.reduce(Data(), +), program = try SolanaSendCrypto.decode(Self.program)
        for bump in (0...255).reversed() {
            let hash = Data(SHA256.hash(data: seed + Data([UInt8(bump)]) + program + Data("ProgramDerivedAddress".utf8)))
            if !SolanaCurve.isPoint(hash) { return (SolanaSendCrypto.encode(hash), UInt8(bump)) }
        }
        throw SolanaSendError.malformed
    }
    /// Reads only the policy needed for authorization. Unexpected authorities,
    /// roles, timelocks, duplicates, allocation or discriminator fail closed.
    public func transactionIndex(account: Data) throws -> UInt64 {
        try validate()
        var r = SolanaMultisigReader(account)
        guard try r.take(8) == Data([224,116,121,186,68,161,79,236]),
              try r.key() == createKey, try r.take(32) == Data(repeating: 0, count: 32),
              try r.number(2) == UInt64(required), try r.number(4) == 0 else { throw SolanaSendError.changed }
        let index = try r.number(8), stale = try r.number(8)
        guard stale <= index, try r.number(1) == 0 else { throw SolanaSendError.changed }
        let bump = try r.number(1)
        guard bump == UInt64(try Self.pda([Data("multisig".utf8), Data("multisig".utf8), SolanaSendCrypto.decode(createKey)]).1),
              try r.number(4) == UInt64(members.count) else { throw SolanaSendError.changed }
        var observed = [String]()
        for _ in members { observed.append(try r.key()); guard try r.number(1) == 7 else { throw SolanaSendError.changed } }
        guard observed.sorted() == members, Set(observed).count == members.count,
              try r.take(r.remaining).allSatisfy({ $0 == 0 }) else { throw SolanaSendError.changed }
        return index
    }
}

/// The fee payer is a member, separate from the program-controlled vault.
public struct SolanaMultisigContext: Codable, Equatable, Sendable {
    public let policy: SolanaMultisigPolicy
    public let index: UInt64
    /// Nil preserves the first-member payer in already journaled plans.
    public let feePayer: String?
    public var payer: String { feePayer ?? policy.payer }
    /// Include the payer among the approvals so selecting a different member
    /// does not add a signature or change the required threshold.
    public var signingMembers: [String] {
        if setupTreasury != nil { return [payer] }
        return [payer] + policy.members.filter { $0 != payer }.prefix(max(0, policy.required - 1))
    }
    public let payerBalance: UInt64
    public let storageRent: UInt64
    public let setupTreasury: String?
    public init(policy: SolanaMultisigPolicy, index: UInt64, payerBalance: UInt64, storageRent: UInt64, setupTreasury: String? = nil, feePayer: String? = nil) {
        self.policy = policy; self.index = index; self.payerBalance = payerBalance; self.storageRent = storageRent; self.setupTreasury = setupTreasury; self.feePayer = feePayer
    }
}

struct SolanaMultisigReader {
    let bytes: Data
    var offset = 0
    init(_ bytes: Data) { self.bytes = bytes }
    var remaining: Int { bytes.count - offset }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw SolanaSendError.malformed }
        defer { offset += count }; return Data(bytes[offset..<offset+count])
    }
    mutating func number(_ count: Int) throws -> UInt64 {
        guard (1...8).contains(count) else { throw SolanaSendError.malformed }
        return try take(count).enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
    }
    mutating func key() throws -> String { SolanaSendCrypto.encode(try take(32)) }
}

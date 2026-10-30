import Foundation
import OathSecp256k1

/// Equal-weight native XRPL signer list. Keep the account identity independent
/// of the signers and order by decoded AccountID, never by Base58 text.
public struct XrplMultisigPolicy: Codable, Sendable, Equatable {
    public static let maximumKeys = 8
    public let account: String
    public let required: Int
    public let signers: [String]
    public init(account: String, required: Int, signers: [String]) throws {
        self.account = account; self.required = required
        self.signers = try signers.map { (try XrplIdentity.accountBytes($0), $0) }
            .sorted { $0.0.lexicographicallyPrecedes($1.0) }.map(\.1)
        try validate()
    }
    public func validate() throws {
        guard try XrplIdentity.address(account) == account,
              (2...Self.maximumKeys).contains(signers.count), (1...signers.count).contains(required),
              Set(signers).count == signers.count, !signers.contains(account) else { throw XrplSendError.unsupportedAccount }
        let ids = try signers.map(XrplIdentity.accountBytes)
        guard ids == ids.sorted(by: { $0.lexicographicallyPrecedes($1) }) else { throw XrplSendError.unsupportedAccount }
    }
    public var entries: XrplJSON { .array(signers.map { .object(["SignerEntry": .object(["Account": .string($0), "SignerWeight": .number("1")])]) }) }
    public func matches(_ list: XrplJSON) -> Bool {
        guard list["SignerQuorum"].integer == UInt64(required), list["SignerListID"].integer == 0,
              let entries = list["SignerEntries"].array, entries.count == signers.count else { return false }
        return zip(entries, signers).allSatisfy { $0.0["SignerEntry"]["Account"].string == $0.1 && $0.0["SignerEntry"]["SignerWeight"].integer == 1 }
    }
}

public enum XrplMultisigSetup: String, Codable, Sendable {
    case signerList, disableMaster
    func transactionJSON(plan: XrplSendPlan, policy: XrplMultisigPolicy) throws -> XrplJSON {
        var tx: [String: XrplJSON] = ["TransactionType": .string(self == .signerList ? "SignerListSet" : "AccountSet"),
            "Account": .string(plan.sender), "Flags": .number("2147483648"), "Sequence": .number(String(plan.sequence)),
            "Fee": .string(String(plan.fee)), "LastLedgerSequence": .number(String(plan.lastLedger))]
        if self == .signerList { tx["SignerQuorum"] = .number(String(policy.required)); tx["SignerEntries"] = policy.entries }
        else { tx["SetFlag"] = .number("4") }
        return .object(tx)
    }
    func bytes(plan: XrplSendPlan, policy: XrplMultisigPolicy, publicKey: Data, signature: Data?) throws -> Data {
        guard publicKey.count == 33, signature == nil || (8...72).contains(signature!.count) else { throw XrplSendError.signing }
        var out = Data([0x12,0,self == .signerList ? 12 : 3,0x22]) + XrplSendCrypto.big(0x80000000,count:4)
        out += Data([0x24]) + XrplSendCrypto.big(UInt64(plan.sequence),count:4)
        out += Data([0x20,0x1b]) + XrplSendCrypto.big(UInt64(plan.lastLedger),count:4)
        out += Data([0x20,self == .signerList ? 0x23 : 0x21]) + XrplSendCrypto.big(UInt64(self == .signerList ? policy.required : 4),count:4)
        out += Data([0x68]) + XrplSendCrypto.big(plan.fee | 0x4000000000000000,count:8)
        out += Data([0x73,33]) + publicKey
        if let signature { out += Data([0x74,UInt8(signature.count)]) + signature }
        out += Data([0x81,20]) + (try XrplIdentity.accountBytes(plan.sender))
        if self == .signerList {
            out += Data([0xf4])
            for signer in policy.signers { out += Data([0xeb,0x13,0,1,0x81,20]) + (try XrplIdentity.accountBytes(signer)) + Data([0xe1]) }
            out += Data([0xf1])
        }
        return out
    }
}

public struct XrplMultisigSignature: Codable, Sendable, Equatable {
    public let account: String
    public let publicKey: Data
    public let signature: Data
    public init(account: String, publicKey: Data, signature: Data) { self.account = account; self.publicKey = publicKey; self.signature = signature }
}
public enum XrplMultisigCrypto {
    public static func sign(_ plan: XrplSendPlan, privateKeys: [Data]) throws -> XrplSignedSend {
        try plan.validate()
        guard let policy = plan.multisig, plan.multisigSetup == nil,
              privateKeys.count == policy.required else { throw XrplSendError.signing }
        let unsigned = try XrplSendCrypto.bytes(plan, publicKey: Data())
        var signers = try privateKeys.map { key in
            let pub = try XrplSendCrypto.publicKey(privateKey:key), account = try XrplSendCrypto.address(publicKey:pub)
            let digest = try XrplSendCrypto.half(Data([0x53,0x4d,0x54,0])+unsigned+XrplIdentity.accountBytes(account))
            return XrplMultisigSignature(account:account,publicKey:pub,signature:try OathSecp256k1.sign(digest,key:key))
        }
        signers = try signers.map { (try XrplIdentity.accountBytes($0.account),$0) }.sorted { $0.0.lexicographicallyPrecedes($1.0) }.map(\.1)
        let bytes = try encode(unsigned, signers:signers, tokenMPT:plan.tokenAuthorization == true && !plan.reference.contains("."))
        let result = XrplSignedSend(bytes:bytes,publicKey:Data(),signature:Data(),hash:XrplSendCrypto.transactionHash(bytes),signers:signers)
        try verify(result,plan:plan); return result
    }
    public static func verify(_ signed: XrplSignedSend, plan: XrplSendPlan) throws {
        try plan.validate(checkAge:false)
        guard let policy = plan.multisig, plan.multisigSetup == nil, let signers = signed.signers,
              signed.publicKey.isEmpty, signed.signature.isEmpty,
              signers.count == policy.required, Set(signers.map(\.account)).count == signers.count,
              signers.allSatisfy({policy.signers.contains($0.account)}) else { throw XrplSendError.signing }
        let ids = try signers.map { try XrplIdentity.accountBytes($0.account) }
        guard ids == ids.sorted(by: { $0.lexicographicallyPrecedes($1) }) else { throw XrplSendError.signing }
        let unsigned = try XrplSendCrypto.bytes(plan,publicKey:Data())
        for signer in signers {
            guard try XrplSendCrypto.address(publicKey:signer.publicKey) == signer.account else { throw XrplSendError.wrongOwner }
            let digest = try XrplSendCrypto.half(Data([0x53,0x4d,0x54,0])+unsigned+XrplIdentity.accountBytes(signer.account))
            try OathSecp256k1.verify(signer.signature,digest:digest,publicKey:signer.publicKey)
        }
        guard signed.bytes == (try encode(unsigned,signers:signers,tokenMPT:plan.tokenAuthorization == true && !plan.reference.contains("."))), signed.hash == XrplSendCrypto.transactionHash(signed.bytes) else { throw XrplSendError.signing }
    }
    private static func encode(_ unsigned: Data, signers: [XrplMultisigSignature], tokenMPT: Bool) throws -> Data {
        let suffix = tokenMPT ? Data(unsigned.suffix(26)) : Data()
        var bytes = (tokenMPT ? Data(unsigned.dropLast(26)) : unsigned) + Data([0xf3])
        for signer in signers {
            guard signer.publicKey.count == 33, (8...72).contains(signer.signature.count) else { throw XrplSendError.signing }
            bytes += Data([0xe0,0x10,0x73,33]) + signer.publicKey
            bytes += Data([0x74,UInt8(signer.signature.count)]) + signer.signature
            bytes += Data([0x81,20]) + (try XrplIdentity.accountBytes(signer.account)) + Data([0xe1])
        }
        return bytes + Data([0xf1]) + suffix
    }
}

public struct XrplMultisigState: Sendable, Equatable {
    public let balance: UInt64, reserve: UInt64
    public let configured: Bool
    public let next: XrplMultisigSetup?
}

/// Native TrustSet / MPTokenAuthorize serialization shares the same multisign
/// domain and durable send journal as payments.
enum XrplTokenAuthorization {
    static func json(_ p: XrplSendPlan) throws -> XrplJSON {
        let issued = p.reference.contains(".")
        var tx: [String:XrplJSON] = ["TransactionType":.string(issued ? "TrustSet":"MPTokenAuthorize"),
            "Account":.string(p.sender),"Flags":.number(issued ? "2147614720":"2147483648"),
            "Fee":.string(String(p.fee)),"Sequence":.number(String(p.sequence)),"LastLedgerSequence":.number(String(p.lastLedger))]
        if issued { tx["LimitAmount"] = try XrplSendAmount.json(reference:p.reference,atomic:p.amount) }
        else { tx["MPTokenIssuanceID"] = .string(p.reference) }
        return .object(tx)
    }
    static func bytes(_ p: XrplSendPlan, publicKey: Data) throws -> Data {
        guard publicKey.isEmpty else { throw XrplSendError.signing }
        let issued = p.reference.contains(".")
        var out = Data([0x12,0,issued ? 20:57,0x22])+XrplSendCrypto.big(issued ? 0x80020000:0x80000000,count:4)
        out += Data([0x24])+XrplSendCrypto.big(UInt64(p.sequence),count:4)
        out += Data([0x20,0x1b])+XrplSendCrypto.big(UInt64(p.lastLedger),count:4)
        if issued { out += Data([0x63])+(try XrplSendCrypto.amount(reference:p.reference,atomic:p.amount)) }
        out += Data([0x68])+XrplSendCrypto.big(p.fee|0x4000000000000000,count:8)
        out += Data([0x73,0,0x81,20])+(try XrplIdentity.accountBytes(p.sender))
        if !issued { out += Data([0x01,0x15])+(try TronIdentity.hex(p.reference)) }
        return out
    }
}

import Foundation
import CryptoKit

/// NEAR core-contracts multisig2, commit 1b0436c96379c63aee7d2429c6d5d24019031ab8.
/// A bootstrap implicit account is secured by removing its full-access key after
/// deployment and verification. Member keys can only call the multisig contract.
public struct NearMultisigPolicy: Codable, Equatable, Sendable {
    public static func freshBootstrapSeed() -> Data { Curve25519.Signing.PrivateKey().rawRepresentation }
    public static let maximumKeys = 10
    public static let codeSHA256 = "f3f9ee3e5e29d020dc73f581ff1490c03dff875ed01327dfebbe666724930a76"
    public static let methods = ["add_request", "delete_request", "confirm", "add_and_confirm_request"]
    public let bootstrap: Data
    public let required: Int
    public let publicKeys: [Data]
    public init(bootstrap: Data, required: Int, publicKeys: [Data]) throws {
        self.bootstrap = bootstrap; self.required = required
        self.publicKeys = publicKeys.sorted { $0.lexicographicallyPrecedes($1) }; try validate()
    }
    public func validate() throws {
        guard bootstrap.count == 32, (2...Self.maximumKeys).contains(publicKeys.count),
              (1...publicKeys.count).contains(required), publicKeys.allSatisfy({ $0.count == 32 }),
              Set(publicKeys).count == publicKeys.count, !publicKeys.contains(bootstrap),
              publicKeys == publicKeys.sorted(by: { $0.lexicographicallyPrecedes($1) }) else { throw NearSendError.changed }
    }
    public var address: String { TronSendCrypto.hex(bootstrap) }
    public static func code() throws -> Data {
        guard let url = Bundle.module.url(forResource: "NearMultisig2", withExtension: "wasm") else { throw NearSendError.configuration }
        let bytes = try Data(contentsOf: url)
        guard TronSendCrypto.hex(Data(SHA256.hash(data: bytes))) == codeSHA256 else { throw NearSendError.changed }
        return bytes
    }
    public static var codeHash: String { get throws { SuiSendCrypto.base58(Data(SHA256.hash(data: try code()))) } }
    var initialization: [String: NearJSON] {
        ["members": .array(publicKeys.map { .object(["public_key": .string(NearSendCrypto.keyString($0))]) }),
         "num_confirmations": .number(String(required))]
    }
}
public struct NearMultisigContext: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable { case deploy, secure, transfer }
    public let policy: NearMultisigPolicy
    public let stage: Stage
    public let requestID: UInt32
    public let nonces: [UInt64]
    public init(policy: NearMultisigPolicy, stage: Stage, requestID: UInt32 = 0, nonces: [UInt64]) {
        self.policy=policy; self.stage=stage; self.requestID=requestID; self.nonces=nonces
    }
    func validate(_ plan: NearSendPlan) throws {
        try policy.validate()
        guard plan.sender == policy.address, plan.publicKey == (stage == .transfer ? policy.publicKeys[0] : policy.bootstrap),
              nonces.count == (stage == .transfer ? policy.required : 1), nonces.allSatisfy({ $0 > 0 && $0 < UInt64.max }),
              nonces.first == plan.nonce else { throw NearSendError.changed }
        if stage != .transfer {
            guard plan.recipient == plan.sender, plan.reference == "native", plan.amount == "1", plan.requestedAmount == "1",
                  plan.decimals == 24, plan.storageDeposit == "0" else { throw NearSendError.changed }
        }
    }
    func request(_ plan: NearSendPlan) throws -> NearJSON {
        var actions: [NearJSON] = []
        if plan.reference == "native" { actions = [.object(["type": .string("Transfer"), "amount": .string(plan.amount)])] }
        else {
            func call(_ name: String, _ args: Data, _ gas: UInt64, _ deposit: String) -> NearJSON {
                .object(["type": .string("FunctionCall"), "method_name": .string(name), "args": .string(args.base64EncodedString()), "gas": .string(String(gas)), "deposit": .string(deposit)])
            }
            if plan.storageDeposit != "0" { actions.append(call("storage_deposit", try NearSendCrypto.storageArgs(plan), plan.storageGas, plan.storageDeposit)) }
            actions.append(call("ft_transfer", try NearSendCrypto.transferArgs(plan), plan.gas, "1"))
        }
        return .object(["receiver_id": .string(plan.reference == "native" ? plan.recipient : plan.reference), "actions": .array(actions)])
    }
}
public struct NearMultisigPart: Codable, Equatable, Sendable {
    public let bytes: Data, publicKey: Data, signature: Data
    public let hash: String
    public var signed: NearSignedSend { .init(bytes: bytes, publicKey: publicKey, signature: signature, hash: hash) }
}
public extension NearSendCrypto {
    static func multisigRaw(_ plan: NearSendPlan) throws -> [(raw: Data, key: Data, nonce: UInt64)] {
        guard let c = plan.multisig else { throw NearSendError.changed }; try c.validate(plan)
        func tx(_ pub: Data, _ nonce: UInt64, _ actions: [Data]) throws -> (Data, Data, UInt64) {
            let raw = text(plan.sender)+Data([0])+pub+le(nonce)+text(plan.sender)+(try SuiSendCrypto.unbase58(plan.blockHash))+le(UInt32(actions.count))+actions.reduce(Data(),+)
            return (raw,pub,nonce)
        }
        switch c.stage {
        case .deploy:
            return [try tx(c.policy.bootstrap,c.nonces[0],[Data([1])+blob(NearMultisigPolicy.code()),call("new",args(c.policy.initialization),100_000_000_000_000,"0")])]
        case .secure: return [try tx(c.policy.bootstrap,c.nonces[0],[Data([6,0])+c.policy.bootstrap])]
        case .transfer:
            var result = [try tx(c.policy.publicKeys[0],c.nonces[0],[call("add_request",args(["request":c.request(plan)]),30_000_000_000_000,"0")])]
            for i in 0..<c.policy.required {
                result.append(try tx(c.policy.publicKeys[i],c.nonces[i]+(i == 0 ? 1:0),[call("confirm",args(["request_id":.number(String(c.requestID))]),150_000_000_000_000,"0")]))
            }
            return result
        }
    }
    static func sign(_ plan: NearSendPlan, privateKeys: [Data], now: Date = .now) throws -> NearSignedSend {
        try plan.validate(now:now)
        let raw = try multisigRaw(plan)
        let keys = try privateKeys.map { try Curve25519.Signing.PrivateKey(rawRepresentation:$0) }
        guard Set(keys.map { $0.publicKey.rawRepresentation }).count == keys.count,
              keys.count == plan.multisig?.nonces.count else { throw NearSendError.signing }
        let parts = try raw.map { value -> NearMultisigPart in
            guard let key=keys.first(where: { $0.publicKey.rawRepresentation == value.key }) else { throw NearSendError.signing }
            let digest=Data(SHA256.hash(data:value.raw)), sig=try key.signature(for:digest)
            return .init(bytes:value.raw+Data([0])+sig,publicKey:value.key,signature:sig,hash:SuiSendCrypto.base58(digest))
        }
        guard let last=parts.last else { throw NearSendError.signing }
        let signed=NearSignedSend(bytes:last.bytes,publicKey:last.publicKey,signature:last.signature,hash:last.hash,multisigParts:parts)
        try verifyMultisig(signed,plan:plan);return signed
    }
    static func verifyMultisig(_ signed: NearSignedSend, plan: NearSendPlan) throws {
        try plan.validate(checkAge:false)
        let raw=try multisigRaw(plan)
        guard let parts=signed.multisigParts,parts.count==raw.count,let last=parts.last,
              signed.bytes==last.bytes,signed.publicKey==last.publicKey,signed.signature==last.signature,signed.hash==last.hash else { throw NearSendError.signing }
        for (part,value) in zip(parts,raw) {
            let digest=Data(SHA256.hash(data:value.raw))
            guard part.publicKey==value.key,part.bytes==value.raw+Data([0])+part.signature,part.signature.count==64,
                  part.hash==SuiSendCrypto.base58(digest),try Curve25519.Signing.PublicKey(rawRepresentation:value.key).isValidSignature(part.signature,for:digest) else { throw NearSendError.signing }
        }
    }
}

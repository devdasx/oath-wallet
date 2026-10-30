import Foundation
import CryptoKit

public enum NearSendCrypto {
    public static func publicKey(privateKey:Data) throws -> Data { try Curve25519.Signing.PrivateKey(rawRepresentation:privateKey).publicKey.rawRepresentation }
    public static func address(privateKey:Data) throws -> String { try TronSendCrypto.hex(publicKey(privateKey:privateKey)) }
    public static func keyString(_ key:Data) -> String { "ed25519:"+SuiSendCrypto.base58(key) }
    public static func sign(_ plan:NearSendPlan,privateKey:Data,now:Date = .now) throws -> NearSignedSend {
        guard plan.multisig == nil else { throw NearSendError.signing }
        try plan.validate(now:now)
        let key=try Curve25519.Signing.PrivateKey(rawRepresentation:privateKey)
        guard key.publicKey.rawRepresentation==plan.publicKey else { throw NearSendError.signing }
        let raw=try raw(plan), digest=Data(SHA256.hash(data:raw)), signature=try key.signature(for:digest)
        let signed=NearSignedSend(bytes:raw+Data([0])+signature,publicKey:plan.publicKey,signature:signature,hash:SuiSendCrypto.base58(digest))
        try verify(signed,plan:plan); return signed
    }
    public static func verify(_ signed:NearSignedSend,plan:NearSendPlan) throws {
        if plan.multisig != nil { try verifyMultisig(signed,plan:plan);return }
        guard signed.multisigParts == nil else { throw NearSendError.signing }
        try plan.validate(checkAge:false)
        let raw=try raw(plan), digest=Data(SHA256.hash(data:raw))
        guard signed.publicKey==plan.publicKey, signed.signature.count==64,
              signed.bytes==raw+Data([0])+signed.signature, signed.hash==SuiSendCrypto.base58(digest),
              try Curve25519.Signing.PublicKey(rawRepresentation:plan.publicKey).isValidSignature(signed.signature,for:digest) else { throw NearSendError.signing }
    }
    static func le<T:FixedWidthInteger>(_ n:T) -> Data { var v=n.littleEndian; return withUnsafeBytes(of:&v) { Data($0) } }
    static func blob(_ b:Data) -> Data { le(UInt32(b.count))+b }
    static func text(_ s:String) -> Data { blob(Data(s.utf8)) }
    static func u128(_ n:String) throws -> Data { _ = try NearSendAmount.checked(n); return Data(try TronSendCrypto.uint256(n).suffix(16).reversed()) }
    static func args(_ values:[String:NearJSON]) throws -> Data { let e=JSONEncoder(); e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]; return try e.encode(NearJSON.object(values)) }
    static func transferArgs(_ plan:NearSendPlan) throws -> Data { try args(["receiver_id":.string(plan.recipient),"amount":.string(plan.amount)]) }
    static func storageArgs(_ plan:NearSendPlan) throws -> Data { try args(["account_id":.string(plan.recipient),"registration_only":.bool(true)]) }
    static func call(_ name:String,_ args:Data,_ gas:UInt64,_ deposit:String) throws -> Data { try Data([2])+text(name)+blob(args)+le(gas)+u128(deposit) }
    public static func raw(_ plan:NearSendPlan) throws -> Data {
        var actions=[Data]()
        if plan.reference=="native" { actions=[try Data([3])+u128(plan.amount)] }
        else {
            if plan.storageDeposit != "0" { actions.append(try call("storage_deposit",storageArgs(plan),plan.storageGas,plan.storageDeposit)) }
            actions.append(try call("ft_transfer",transferArgs(plan),plan.gas,"1"))
        }
        let block=try SuiSendCrypto.unbase58(plan.blockHash)
        guard block.count==32 else { throw NearSendError.malformed }
        return text(plan.sender)+Data([0])+plan.publicKey+le(plan.nonce)+text(plan.receiver)+block+le(UInt32(actions.count))+actions.reduce(Data(),+)
    }
}

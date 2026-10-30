import Foundation
import OathSecp256k1

/// EIP-1559 and replay-protected EIP-155 transactions, built locally from the approved plan. Providers
/// supply state and estimates, never destinations, calldata, or signing payloads.
public enum EVMSendCrypto {
    public static func address(privateKey:Data) throws -> String { try address(publicKey:OathSecp256k1.publicKey(privateKey,compressed:false)) }
    private static func address(publicKey:Data) throws -> String {
        guard publicKey.count==65,publicKey.first==4 else { throw EVMSendError.signing }
        return "0x"+TronSendCrypto.hex(TronSendCrypto.keccak(Data(publicKey.dropFirst())).suffix(20))
    }
    public static func data(_ plan:EVMSendPlan) throws -> Data {
        if let call=plan.call { try call.validate(); return call.bytes }
        if let removal=plan.removal { return try removal.calldata() }
        if plan.reference == "native" { return Data() }
        return try TronIdentity.hex("a9059cbb")+Data(repeating:0,count:12)+TronIdentity.hex(plan.recipient)+TronSendCrypto.uint256(plan.amount)
    }
    private static func fields(_ plan:EVMSendPlan,authorization:Data?=nil) throws -> [Data] {
        if plan.legacy {
            return try [integer(String(plan.nonce)),integer(String(plan.maxFeePerGas)),integer(String(plan.gasLimit)),
                        rlp(TronIdentity.hex(plan.receiver)),integer(plan.value),rlp(data(plan))]
        }
        var result = try [integer(String(plan.network.chainID)),integer(String(plan.nonce)),integer(String(plan.maxPriorityFeePerGas)),
             integer(String(plan.maxFeePerGas)),integer(String(plan.gasLimit)),rlp(TronIdentity.hex(plan.receiver)),
             integer(plan.value),rlp(data(plan)),list([])]
        if plan.removal?.kind == .delegation {
            // Fee-oracle sizing uses worst-case nonzero signature bytes. Actual
            // signing always supplies the separately verified authorization.
            let sig=authorization ?? Data(repeating:0xff,count:64)+Data([1])
            guard sig.count==65,sig[64]<=1 else {throw EVMSendError.signing}
            result.append(list([list([try integer(String(plan.network.chainID)),rlp(Data(repeating:0,count:20)),try integer(String(plan.nonce+1)),try integer(String(sig[64])),rlp(trim(Data(sig.prefix(32)))),rlp(trim(Data(sig.dropFirst(32).prefix(32))))])]))
        }
        return result
    }
    public static func unsignedBytes(_ plan:EVMSendPlan,authorization:Data?=nil) throws -> Data {
        if plan.legacy { return list(try fields(plan)+[integer(String(plan.network.chainID)),rlp(Data()),rlp(Data())]) }
        return Data([plan.removal?.kind == .delegation ? 4:2])+list(try fields(plan,authorization:authorization))
    }
    public static func sign(_ plan:EVMSendPlan,privateKey:Data,now:Date = .now) throws -> EVMSignedSend {
        try plan.validate(now:now)
        guard plan.multisig == nil else { throw EVMSendError.wrongOwner }
        guard try address(privateKey:privateKey)==plan.sender else { throw EVMSendError.wrongOwner }
        let authorization=plan.removal?.kind == .delegation ? try OathSecp256k1.signRecoverable(authorizationDigest(plan),key:privateKey):nil
        let digest=TronSendCrypto.keccak(try unsignedBytes(plan,authorization:authorization))
        let sig=try OathSecp256k1.signRecoverable(digest,key:privateKey)
        guard sig.count==65,sig[64]<=1 else { throw EVMSendError.signing }
        let raw=try signedBytes(plan,sig,authorization:authorization)
        let result=EVMSignedSend(bytes:raw,signature:sig,hash:"0x"+TronSendCrypto.hex(TronSendCrypto.keccak(raw)),authorizationSignature:authorization)
        try verify(result,plan:plan); return result
    }
    public static func verify(_ signed:EVMSignedSend,plan:EVMSendPlan) throws {
        if plan.multisig != nil { try EVMMultisigCrypto.verify(signed, plan: plan); return }
        guard signed.multisigSignatures == nil else { throw EVMSendError.signing }
        try plan.validate(checkAge:false)
        guard signed.signature.count==65,signed.signature[64]<=1 else { throw EVMSendError.signing }
        if plan.removal?.kind == .delegation {
            guard let auth=signed.authorizationSignature,auth.count==65,auth[64]<=1,
                  try address(publicKey:OathSecp256k1.recover(auth,digest:authorizationDigest(plan)))==plan.sender else {throw EVMSendError.signing}
        } else {guard signed.authorizationSignature==nil else {throw EVMSendError.signing}}
        let digest=TronSendCrypto.keccak(try unsignedBytes(plan,authorization:signed.authorizationSignature))
        guard try address(publicKey:OathSecp256k1.recover(signed.signature,digest:digest))==plan.sender,
              signed.bytes == (try signedBytes(plan,signed.signature,authorization:signed.authorizationSignature)),
              signed.hash == "0x"+TronSendCrypto.hex(TronSendCrypto.keccak(signed.bytes)) else { throw EVMSendError.signing }
    }
    private static func signedBytes(_ plan:EVMSendPlan,_ sig:Data,authorization:Data?) throws -> Data {
        let v = plan.legacy ? plan.network.chainID*2+35+UInt64(sig[64]) : UInt64(sig[64])
        return (plan.legacy ? Data():Data([plan.removal?.kind == .delegation ? 4:2]))+list(try fields(plan,authorization:authorization)+[integer(String(v)),rlp(trim(Data(sig.prefix(32)))),rlp(trim(Data(sig.dropFirst(32).prefix(32))))])
    }
    private static func authorizationDigest(_ plan:EVMSendPlan) throws -> Data {
        // Self-sponsored authorization is applied after the outer nonce increment.
        // Never sign a wildcard chain or a nonzero delegate in a removal flow.
        guard plan.nonce<UInt64.max-1 else {throw EVMSendError.signing}
        return TronSendCrypto.keccak(Data([5])+list(try [integer(String(plan.network.chainID)),rlp(Data(repeating:0,count:20)),integer(String(plan.nonce+1))]))
    }
    private static func trim(_ bytes:Data) -> Data { Data(bytes.drop(while:{$0==0})) }
    private static func integer(_ n:String) throws -> Data { rlp(trim(try TronSendCrypto.uint256(n))) }
    private static func length(_ size:Int,_ short:UInt8,_ long:UInt8) -> Data {
        if size<=55 { return Data([short+UInt8(size)]) }
        var n=size,bytes=[UInt8]();while n>0 { bytes.insert(UInt8(n&255),at:0);n>>=8 }
        return Data([long+UInt8(bytes.count)]+bytes)
    }
    private static func rlp(_ data:Data) -> Data {
        if data.count==1,data.first!<128 { return data }
        return length(data.count,128,183)+data
    }
    private static func list(_ items:[Data]) -> Data { let data=items.reduce(Data(),+);return length(data.count,192,247)+data }
}

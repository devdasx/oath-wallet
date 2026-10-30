import Foundation
import OathSecp256k1

/// EIP-1559 typed transactions, built locally from the approved plan. Providers
/// supply state and estimates, never destinations, calldata, or signing payloads.
public enum ArcSendCrypto {
    public static func address(privateKey:Data) throws -> String { try address(publicKey:OathSecp256k1.publicKey(privateKey,compressed:false)) }
    private static func address(publicKey:Data) throws -> String {
        guard publicKey.count==65,publicKey.first==4 else { throw ArcSendError.signing }
        return "0x"+TronSendCrypto.hex(TronSendCrypto.keccak(Data(publicKey.dropFirst())).suffix(20))
    }
    public static func data(_ plan:ArcSendPlan) throws -> Data {
        if plan.reference == "native" { return Data() }
        return try TronIdentity.hex("a9059cbb")+Data(repeating:0,count:12)+TronIdentity.hex(plan.recipient)+TronSendCrypto.uint256(plan.amount)
    }
    private static func fields(_ plan:ArcSendPlan) throws -> [Data] {
        try [integer(String(plan.network.chainID)),integer(String(plan.nonce)),integer(String(plan.maxPriorityFeePerGas)),
             integer(String(plan.maxFeePerGas)),integer(String(plan.gasLimit)),rlp(TronIdentity.hex(plan.receiver)),
             integer(plan.value),rlp(data(plan)),list([])]
    }
    public static func sign(_ plan:ArcSendPlan,privateKey:Data,now:Date = .now) throws -> ArcSignedSend {
        try plan.validate(now:now)
        guard try address(privateKey:privateKey)==plan.sender else { throw ArcSendError.wrongOwner }
        let digest=TronSendCrypto.keccak(Data([2])+list(try fields(plan)))
        let sig=try OathSecp256k1.signRecoverable(digest,key:privateKey)
        guard sig.count==65,sig[64]<=1 else { throw ArcSendError.signing }
        let raw=try signedBytes(plan,sig)
        let result=ArcSignedSend(bytes:raw,signature:sig,hash:"0x"+TronSendCrypto.hex(TronSendCrypto.keccak(raw)))
        try verify(result,plan:plan); return result
    }
    public static func verify(_ signed:ArcSignedSend,plan:ArcSendPlan) throws {
        try plan.validate(checkAge:false)
        guard signed.signature.count==65,signed.signature[64]<=1 else { throw ArcSendError.signing }
        let digest=TronSendCrypto.keccak(Data([2])+list(try fields(plan)))
        guard try address(publicKey:OathSecp256k1.recover(signed.signature,digest:digest))==plan.sender,
              signed.bytes == (try signedBytes(plan,signed.signature)),
              signed.hash == "0x"+TronSendCrypto.hex(TronSendCrypto.keccak(signed.bytes)) else { throw ArcSendError.signing }
    }
    private static func signedBytes(_ plan:ArcSendPlan,_ sig:Data) throws -> Data {
        Data([2])+list(try fields(plan)+[integer(String(sig[64])),rlp(trim(Data(sig.prefix(32)))),rlp(trim(Data(sig.dropFirst(32).prefix(32))))])
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

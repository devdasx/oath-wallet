import Foundation
import CryptoKit
import OathSecp256k1

/// Cosmos SIGN_MODE_DIRECT with THORChain's /types.MsgSend (byte addresses).
/// The transaction and sign document are built only from the approved plan.
public enum ThorchainSendCrypto {
    public static func publicKey(privateKey:Data) throws -> Data { try OathSecp256k1.publicKey(privateKey) }
    public static func address(publicKey:Data,network:ThorchainSendNetwork) throws -> String {
        guard publicKey.count==33,[2,3].contains(publicKey.first!) else { throw ThorchainSendError.signing }
        return bech32(XrplRIPEMD160.hash(Data(SHA256.hash(data:publicKey))),prefix:network.prefix)
    }
    public static func addressBytes(_ address:String,network:ThorchainSendNetwork) throws -> Data {
        guard address==address.lowercased(),address.hasPrefix(network.prefix+"1"),[network.prefix.count+39,network.prefix.count+59].contains(address.count) else { throw ThorchainSendError.wrongNetwork }
        let alphabet=Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
        let words=try address.dropFirst(network.prefix.count+1).map { c -> UInt8 in
            guard let n=alphabet.firstIndex(of:c) else { throw ThorchainSendError.malformed };return UInt8(n)
        }
        guard polymod(expand(network.prefix)+words)==1 else { throw ThorchainSendError.malformed }
        var accumulator:UInt32=0,bits=0,result=Data()
        for w in words.dropLast(6) { accumulator=(accumulator<<5)|UInt32(w);bits+=5;if bits>=8 {bits-=8;result.append(UInt8(truncatingIfNeeded:accumulator>>bits))} }
        guard bits<5,(accumulator & ((1<<bits)-1))==0,[20,32].contains(result.count) else {throw ThorchainSendError.malformed}
        return result
    }
    private static func expand(_ prefix:String)->[UInt8] { prefix.utf8.map{$0>>5}+[0]+prefix.utf8.map{$0&31} }
    private static func polymod(_ words:[UInt8])->UInt32 {
        var value:UInt32=1
        for w in words { let top=value>>25;value=((value&0x1ffffff)<<5)^UInt32(w);for (i,g) in [UInt32(0x3b6a57b2),0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3].enumerated() where (top>>i)&1 != 0 {value ^= g} }
        return value
    }
    static func bech32(_ bytes:Data,prefix:String)->String {
        var accumulator:UInt32=0,bits=0,words=[UInt8]()
        for b in bytes {accumulator=(accumulator<<8)|UInt32(b);bits+=8;while bits>=5 {bits-=5;words.append(UInt8((accumulator>>bits)&31))} }
        if bits>0 {words.append(UInt8((accumulator<<(5-bits))&31))}
        let mod=polymod(expand(prefix)+words+Array(repeating:0,count:6))^1
        words += (0..<6).map{UInt8((mod>>(5*(5-$0)))&31)}
        let alphabet=Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
        return prefix+"1"+String(words.map{alphabet[Int($0)]})
    }
    private static func text(_ tag:UInt64,_ value:String)->Data { TronSendCrypto.field(tag,Data(value.utf8)) }
    private static func any(_ type:String,_ bytes:Data)->Data { text(1,type)+TronSendCrypto.field(2,bytes) }
    public static func body(_ p:ThorchainSendPlan) throws -> Data {
        let coin=text(1,p.denom)+text(2,p.amount)
        let message=try TronSendCrypto.field(1,addressBytes(p.sender,network:p.network))+TronSendCrypto.field(2,addressBytes(p.recipient,network:p.network))+TronSendCrypto.field(3,coin)
        return TronSendCrypto.field(1,any("/types.MsgSend",message))+text(2,p.memo)+TronSendCrypto.number(3,p.timeoutHeight)
    }
    public static func auth(_ p:ThorchainSendPlan)->Data {
        let key=any("/cosmos.crypto.secp256k1.PubKey",TronSendCrypto.field(1,p.publicKey))
        let mode=TronSendCrypto.field(1,TronSendCrypto.number(1,1))
        let signer=TronSendCrypto.field(1,key)+TronSendCrypto.field(2,mode)+TronSendCrypto.number(3,p.sequence)
        // Native fee is deducted by THORNode's ante handler, not Cosmos gas fees.
        return TronSendCrypto.field(1,signer)+TronSendCrypto.field(2,TronSendCrypto.number(2,ThorchainSendPlan.gasLimit))
    }
    public static func signDoc(_ p:ThorchainSendPlan) throws -> Data {
        try TronSendCrypto.field(1,body(p))+TronSendCrypto.field(2,auth(p))+text(3,p.network.chainID)+TronSendCrypto.number(4,p.accountNumber)
    }
    private static func signedBytes(_ p:ThorchainSendPlan,_ signature:Data) throws -> Data { try TronSendCrypto.field(1,body(p))+TronSendCrypto.field(2,auth(p))+TronSendCrypto.field(3,Data(signature.prefix(64))) }
    public static func sign(_ plan:ThorchainSendPlan,privateKey:Data,now:Date = .now) throws -> ThorchainSignedSend {
        try plan.validate(now:now)
        guard plan.multisig == nil else { throw ThorchainSendError.signing }
        guard try publicKey(privateKey:privateKey)==plan.publicKey else {throw ThorchainSendError.wrongOwner}
        let sig=try OathSecp256k1.signRecoverable(Data(SHA256.hash(data:signDoc(plan))),key:privateKey)
        let bytes=try signedBytes(plan,sig)
        let signed=ThorchainSignedSend(bytes:bytes,signature:sig,hash:TronSendCrypto.hex(Data(SHA256.hash(data:bytes))).uppercased())
        try verify(signed,plan:plan);return signed
    }
    public static func verify(_ signed:ThorchainSignedSend,plan:ThorchainSendPlan) throws {
        try plan.validate(checkAge:false)
        if plan.multisig != nil { try verifyMultisig(signed, plan: plan); return }
        let publicKey=try OathSecp256k1.recover(signed.signature,digest:Data(SHA256.hash(data:signDoc(plan))))
        let compressed=Data([publicKey.last!&1 == 0 ? 2:3])+publicKey.dropFirst().prefix(32)
        guard compressed==plan.publicKey,signed.bytes==(try signedBytes(plan,signed.signature)),signed.hash==TronSendCrypto.hex(Data(SHA256.hash(data:signed.bytes))).uppercased() else {throw ThorchainSendError.signing}
    }
}

extension ThorchainSendCrypto {
    /// Authenticate a committed transaction before using its sequence as proof
    /// of replacement. Different messages are permitted, but no unsigned JSON
    /// field can release the original pending payment.
    static func committedSequence(_ raw:Data,publicKey:Data,accountNumber:UInt64,network:ThorchainSendNetwork) throws -> UInt64 {
        let tx=try protobuf(raw),body=try one(tx,1),auth=try one(tx,2),signature=try one(tx,3)
        guard signature.count==64 else {throw ThorchainSendError.malformed}
        let authFields=try protobuf(auth),signer=try protobuf(one(authFields,1))
        let keyAny=try protobuf(one(signer,1))
        guard String(data:try one(keyAny,1),encoding:.utf8)=="/cosmos.crypto.secp256k1.PubKey",
              try one(protobuf(one(keyAny,2)),1)==publicKey else {throw ThorchainSendError.wrongOwner}
        let mode=try protobuf(one(signer,2)),single=try protobuf(one(mode,1))
        guard single[1]?.count==1,single[1]?.first?.number==1 else {throw ThorchainSendError.signing}
        let sequence=signer[3]?.first?.number ?? 0
        guard signer[3]==nil || signer[3]?.count==1 else {throw ThorchainSendError.malformed}
        let doc=TronSendCrypto.field(1,body)+TronSendCrypto.field(2,auth)+TronSendCrypto.field(3,Data(network.chainID.utf8))+TronSendCrypto.number(4,accountNumber)
        let digest=Data(SHA256.hash(data:doc))
        for recovery:UInt8 in [0,1] {
            // An alternative recovery candidate is expected, not a failure.
            if let recovered=try? OathSecp256k1.recover(signature+Data([recovery]),digest:digest) {
                let compressed=Data([recovered.last!&1 == 0 ? 2:3])+recovered.dropFirst().prefix(32)
                if compressed==publicKey {return sequence}
            }
        }
        throw ThorchainSendError.signing
    }
    /// Prove a competing native bank send with the same multisig policy before
    /// releasing a reserved sequence. Other message families remain unknown.
    static func committedMultisigSequence(_ raw: Data, plan: ThorchainSendPlan) throws -> UInt64? {
        guard let policy = plan.multisig else { throw ThorchainSendError.signing }
        let tx = try protobuf(raw), body = try protobuf(one(tx,1)), auth = try protobuf(one(tx,2))
        let message = try protobuf(one(body,1))
        guard String(data: try one(message,1),encoding:.utf8) == "/types.MsgSend" else { return nil }
        let send = try protobuf(one(message,2)), coin = try protobuf(one(send,3))
        guard try one(send,1) == addressBytes(plan.sender,network:plan.network),
              let denom = String(data:try one(coin,1),encoding:.utf8),
              let amount = String(data:try one(coin,2),encoding:.utf8) else { throw ThorchainSendError.wrongOwner }
        let recipientBytes = try one(send,2)
        guard [20,32].contains(recipientBytes.count) else { throw ThorchainSendError.malformed }
        let signer = try protobuf(one(auth,1)), mode = try protobuf(one(signer,2)), multi = try protobuf(one(mode,2))
        let bitArray = try protobuf(one(multi,1)), elems = try one(bitArray,2)
        guard elems.count == (policy.publicKeys.count+7)/8,
              (bitArray[1]?.first?.number ?? 0) == UInt64(policy.publicKeys.count%8) else { throw ThorchainSendError.signing }
        let sequence = signer[3]?.first?.number ?? 0, timeout = body[3]?.first?.number ?? 0
        let memo: String
        if body[2] == nil { memo = "" }
        else { guard let text = String(data:try one(body,2),encoding:.utf8) else { throw ThorchainSendError.malformed }; memo = text }
        let candidate = ThorchainSendPlan(network:plan.network,sender:plan.sender,
            recipient:bech32(recipientBytes,prefix:plan.network.prefix),reference:denom == "rune" ? "native":denom,
            memo:memo,publicKey:plan.publicKey,decimals:plan.decimals,requestedAmount:amount,amount:amount,
            assetBalance:plan.assetBalance,nativeBalance:plan.nativeBalance,accountNumber:plan.accountNumber,
            sequence:sequence,fee:plan.fee,height:plan.height,timeoutHeight:timeout,createdAt:plan.createdAt,multisig:policy)
        let digest = Data(SHA256.hash(data:try multisigSignDoc(candidate)))
        let signatures = try protobuf(one(tx,3))[1] ?? []
        let indices = policy.publicKeys.indices.filter { elems[$0/8] & (1 << (7-$0%8)) != 0 }
        guard signatures.count == indices.count, signatures.count >= policy.required else { throw ThorchainSendError.signing }
        var envelope = Data([1, UInt8(indices.count)])
        for (position,index) in indices.enumerated() {
            guard let signature = signatures[position].bytes, signature.count == 64 else { throw ThorchainSendError.signing }
            var matched: Data?
            for recovery: UInt8 in 0...3 {
                // Alternative recovery candidates are expected, not failures.
                if let key = try? OathSecp256k1.recover(signature+Data([recovery]),digest:digest) {
                    let compressed = Data([key.last! & 1 == 0 ? 2:3])+key.dropFirst().prefix(32)
                    if compressed == policy.publicKeys[index] { matched = signature+Data([recovery]); break }
                }
            }
            guard let matched else { throw ThorchainSendError.signing }
            envelope += Data([UInt8(index)])+matched
        }
        try verifyMultisig(.init(bytes:raw,signature:envelope,hash:TronSendCrypto.hex(Data(SHA256.hash(data:raw))).uppercased()),plan:candidate)
        return sequence
    }
    private struct ProtoField {let bytes:Data?,number:UInt64?}
    private static func one(_ fields:[UInt64:[ProtoField]],_ tag:UInt64) throws -> Data {
        guard fields[tag]?.count==1,let bytes=fields[tag]?.first?.bytes else {throw ThorchainSendError.malformed};return bytes
    }
    private static func protobuf(_ data:Data) throws -> [UInt64:[ProtoField]] {
        guard data.count<=1_048_576 else {throw ThorchainSendError.malformed}
        let bytes=Array(data);var index=0,result=[UInt64:[ProtoField]]()
        func number() throws -> UInt64 {
            var n:UInt64=0
            for shift in stride(from:0,through:63,by:7) {
                guard index<bytes.count else {throw ThorchainSendError.malformed};let byte=bytes[index];index+=1
                guard shift<63 || byte<=1 else {throw ThorchainSendError.malformed}
                n |= UInt64(byte&127)<<shift;if byte&128==0 {return n}
            };throw ThorchainSendError.malformed
        }
        while index<bytes.count {
            let key=try number(),tag=key>>3;guard tag>0 else {throw ThorchainSendError.malformed}
            switch key&7 {
            case 0: result[tag,default:[]].append(.init(bytes:nil,number:try number()))
            case 2:
                let length=try number();guard length<=UInt64(bytes.count-index) else {throw ThorchainSendError.malformed}
                let end=index+Int(length);result[tag,default:[]].append(.init(bytes:Data(bytes[index..<end]),number:nil));index=end
            default: throw ThorchainSendError.malformed
            }
        };return result
    }
}

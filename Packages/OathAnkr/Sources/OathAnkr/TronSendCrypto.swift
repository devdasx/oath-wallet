import Foundation
import CryptoKit
import OathSecp256k1

public enum TronSendCrypto {
    public static func address(privateKey: Data) throws -> String {
        try address(publicKey:OathSecp256k1.publicKey(privateKey,compressed:false))
    }
    static func address(publicKey: Data) throws -> String {
        guard publicKey.count==65,publicKey.first==4 else { throw TronSendError.signing }
        return try TronIdentity.address(hex(keccak(Data(publicKey.dropFirst())).suffix(20)))
    }
    public static func sign(_ plan:TronSendPlan,privateKey:Data,now:Date = .now) throws -> TronSignedSend {
        try sign(plan, privateKeys: [privateKey], now: now)
    }
    public static func sign(_ plan: TronSendPlan, privateKeys: [Data], now: Date = .now) throws -> TronSignedSend {
        try plan.validate(now: now)
        let expected = plan.multisig.map { Set($0.signers) } ?? [plan.sender]
        let addresses = try privateKeys.map { try address(privateKey: $0) }
        guard privateKeys.count == (plan.multisig?.required ?? 1), Set(addresses).count == addresses.count,
              Set(addresses).isSubset(of: expected) else { throw TronSendError.signing }
        let raw = try raw(plan), digest = Data(SHA256.hash(data: raw))
        let signatures = try privateKeys.map { key in
            var signature = try OathSecp256k1.signRecoverable(digest, key: key)
            signature[64] += 27; return signature
        }
        let bytes = signatures.reduce(field(1, raw)) { $0 + field(2, $1) }
        let signed = TronSignedSend(bytes: bytes, signature: signatures[0], hash: hex(digest),
                                   additionalSignatures: signatures.count > 1 ? Array(signatures.dropFirst()) : nil)
        try verify(signed, plan: plan); return signed
    }
    public static func verify(_ signed:TronSignedSend,plan:TronSendPlan) throws {
        try plan.validate(checkAge:false)
        let raw=try raw(plan),digest=Data(SHA256.hash(data:raw)), signatures = signed.signatures
        guard signatures.count == (plan.multisig?.required ?? 1), signed.hash == hex(digest),
              signed.bytes == signatures.reduce(field(1,raw), { $0 + field(2,$1) }) else { throw TronSendError.signing }
        let addresses = try signatures.map { signature in
            guard signature.count == 65, (27...30).contains(signature[64]) else { throw TronSendError.signing }
            var recovery = signature; recovery[64] -= 27
            return try address(publicKey: OathSecp256k1.recover(recovery, digest: digest))
        }
        let expected = plan.multisig.map { Set($0.signers) } ?? [plan.sender]
        guard Set(addresses).count == addresses.count, Set(addresses).isSubset(of: expected) else { throw TronSendError.signing }
    }
    static func hex(_ data:Data) -> String { data.map { String(format:"%02x",$0) }.joined() }
    static func varint(_ value:UInt64) -> Data {
        var n=value,out=Data();repeat { var b=UInt8(n&127);n>>=7;if n>0 { b|=128 };out.append(b) } while n>0;return out
    }
    static func number(_ tag:UInt64,_ n:UInt64) -> Data { n==0 ? Data():varint(tag<<3)+varint(n) }
    static func field(_ tag:UInt64,_ bytes:Data) -> Data { bytes.isEmpty ? Data():varint(tag<<3|2)+varint(UInt64(bytes.count))+bytes }
    public static func raw(_ plan:TronSendPlan) throws -> Data {
        let owner=try TronIdentity.bytes(plan.sender),to=try TronIdentity.bytes(plan.recipient)
        let type:UInt64,name:String,value:Data
        if let setup = plan.multisigSetup {
            type=46;name="AccountPermissionUpdateContract";value=try setup.contract(account:plan.sender)
        } else if let control=plan.removal?.control {
            type=46;name="AccountPermissionUpdateContract";value=try control.contract(signer:plan.sender)
        } else if let removal=plan.removal {
            type=31;name="TriggerSmartContract"
            value=field(1,owner)+field(2,try TronIdentity.bytes(removal.contract))+field(4,try removal.calldata())
        } else if plan.reference=="native" {
            guard let n=UInt64(plan.amount),n<=UInt64(Int64.max) else { throw TronSendError.amount }
            type=1;name="TransferContract";value=field(1,owner)+field(2,to)+number(3,n)
        } else if TronIdentity.isTRC10(plan.reference) {
            guard let n=UInt64(plan.amount),n<=UInt64(Int64.max) else { throw TronSendError.amount }
            type=2;name="TransferAssetContract";value=field(1,Data(plan.reference.utf8))+field(2,owner)+field(3,to)+number(4,n)
        } else {
            type=31;name="TriggerSmartContract"
            value=field(1,owner)+field(2,try TronIdentity.bytes(plan.reference))+field(4,try transferData(recipient:plan.recipient,amount:plan.amount))
        }
        let any=field(1,Data(("type.googleapis.com/protocol."+name).utf8))+field(2,value)
        let contract=number(1,type)+field(2,any)+number(5,plan.multisig == nil ? 0 : 2)
        let id=try TronIdentity.hex(plan.blockID)
        guard id.count==32 else { throw TronSendError.malformed }
        return field(1,Data(id[6..<8]))+field(4,Data(id[8..<16]))+number(8,plan.expiration)+field(11,contract)+number(14,plan.timestamp)+number(18,plan.feeLimit)
    }
    static func transferData(recipient:String,amount:String) throws -> Data {
        try TronIdentity.hex("a9059cbb")+Data(repeating:0,count:12)+TronIdentity.bytes(recipient).dropFirst()+uint256(amount)
    }
    static func uint256(_ raw:String) throws -> Data {
        guard !raw.isEmpty,raw.count<=78,raw.utf8.allSatisfy({(48...57).contains($0)}) else { throw TronSendError.amount }
        var bytes=[UInt8](repeating:0,count:32)
        for c in raw.utf8 { var carry=Int(c-48);for i in bytes.indices.reversed() { carry+=Int(bytes[i])*10;bytes[i]=UInt8(carry&255);carry>>=8 };guard carry==0 else { throw TronSendError.amount } }
        return Data(bytes)
    }
    /// Keccak-256, legacy Keccak padding (TRON account identifiers), not SHA3-256.
    public static func keccak(_ data:Data) -> Data {
        sponge256(data, suffix: 1)
    }
    /// FIPS 202 SHA3-256 uses a different domain suffix than legacy Keccak.
    static func sha3(_ data: Data) -> Data { sponge256(data, suffix: 6) }
    private static func sponge256(_ data: Data, suffix: UInt8) -> Data {
        let rc:[UInt64]=[0x1,0x8082,0x800000000000808a,0x8000000080008000,0x808b,0x80000001,0x8000000080008081,0x8000000000008009,0x8a,0x88,0x80008009,0x8000000a,0x8000808b,0x800000000000008b,0x8000000000008089,0x8000000000008003,0x8000000000008002,0x8000000000000080,0x800a,0x800000008000000a,0x8000000080008081,0x8000000000008080,0x80000001,0x8000000080008008]
        let rotations=[0,1,62,28,27,36,44,6,55,20,3,10,43,25,39,41,45,15,21,8,18,2,61,56,14]
        func rotate(_ x:UInt64,_ n:Int)->UInt64 { n==0 ? x:(x<<n)|(x>>(64-n)) }
        var bytes=Array(data);bytes.append(suffix);while bytes.count%136 != 0 { bytes.append(0) };bytes[bytes.count-1] |= 128
        var a=[UInt64](repeating:0,count:25)
        for offset in stride(from:0,to:bytes.count,by:136) {
            for i in 0..<136 { a[i/8]^=UInt64(bytes[offset+i])<<((i%8)*8) }
            for round in 0..<24 {
                var c=[UInt64](repeating:0,count:5),d=c,b=a
                for x in 0..<5 { c[x]=a[x]^a[x+5]^a[x+10]^a[x+15]^a[x+20] }
                for x in 0..<5 { d[x]=c[(x+4)%5]^rotate(c[(x+1)%5],1) }
                for i in 0..<25 { a[i]^=d[i%5] }
                for y in 0..<5 { for x in 0..<5 { b[y+5*((2*x+3*y)%5)]=rotate(a[x+5*y],rotations[x+5*y]) } }
                for y in 0..<5 { for x in 0..<5 { a[x+5*y]=b[x+5*y]^((~b[(x+1)%5+5*y])&b[(x+2)%5+5*y]) } }
                a[0]^=rc[round]
            }
        }
        return Data((0..<32).map { UInt8(truncatingIfNeeded:a[$0/8]>>(($0%8)*8)) })
    }
}

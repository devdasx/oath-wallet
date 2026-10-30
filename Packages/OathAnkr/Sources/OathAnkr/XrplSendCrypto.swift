import Foundation
import CryptoKit
import OathSecp256k1

/// XRPL's canonical binary Payment / AccountDelete format. Signing uses libsecp256k1's
/// deterministic, low-S DER signatures; private keys never enter an RPC.
public enum XrplSendCrypto {
    public static func publicKey(privateKey: Data) throws -> Data {
        try OathSecp256k1.publicKey(privateKey)
    }
    public static func address(privateKey: Data) throws -> String { try address(publicKey:publicKey(privateKey:privateKey)) }
    public static func address(publicKey: Data) throws -> String {
        guard publicKey.count == 33, [2,3].contains(publicKey.first!) else { throw XrplSendError.signing }
        let payload = Data([0])+XrplRIPEMD160.hash(Data(SHA256.hash(data:publicKey)))
        let bytes = payload+Data(SHA256.hash(data:Data(SHA256.hash(data:payload)))).prefix(4)
        let alphabet = Array("rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz".utf8)
        var digits = [Int]()
        for byte in bytes {
            var carry = Int(byte)
            for i in digits.indices { carry += digits[i]*256; digits[i] = carry%58; carry /= 58 }
            while carry > 0 { digits.append(carry%58); carry /= 58 }
        }
        return String(decoding:Array(repeating:alphabet[0],count:bytes.prefix(while:{$0 == 0}).count)+digits.reversed().map{alphabet[$0]},as:UTF8.self)
    }
    public static func sign(_ plan: XrplSendPlan, privateKey: Data) throws -> XrplSignedSend {
        try plan.validate()
        guard plan.multisig == nil || plan.multisigSetup != nil else { throw XrplSendError.wrongOwner }
        let pub = try publicKey(privateKey:privateKey)
        guard try address(publicKey:pub) == plan.sender else { throw XrplSendError.wrongOwner }
        let digest = half(Data([0x53,0x54,0x58,0])+(try bytes(plan,publicKey:pub)))
        let signature = try OathSecp256k1.sign(digest,key:privateKey), raw = try bytes(plan,publicKey:pub,signature:signature)
        let signed = XrplSignedSend(bytes:raw,publicKey:pub,signature:signature,hash:transactionHash(raw))
        try verify(signed,plan:plan); return signed
    }
    public static func verify(_ signed: XrplSignedSend, plan: XrplSendPlan) throws {
        try plan.validate(checkAge:false)
        if plan.multisig != nil && plan.multisigSetup == nil { return try XrplMultisigCrypto.verify(signed, plan: plan) }
        guard signed.signers == nil else { throw XrplSendError.signing }
        guard try address(publicKey:signed.publicKey) == plan.sender,
              signed.hash == transactionHash(signed.bytes),
              signed.bytes == (try bytes(plan,publicKey:signed.publicKey,signature:signed.signature)),
              signed.publicKey.count == 33 else { throw XrplSendError.signing }
        let digest = half(Data([0x53,0x54,0x58,0])+(try bytes(plan,publicKey:signed.publicKey)))
        try OathSecp256k1.verify(signed.signature,digest:digest,publicKey:signed.publicKey)
    }
    public static func transactionHash(_ bytes: Data) -> String { hex(half(Data([0x54,0x58,0x4E,0])+bytes)) }
    static func half(_ bytes: Data) -> Data { Data(SHA512.hash(data:bytes).prefix(32)) }
    public static func hex(_ bytes: Data) -> String { bytes.map { String(format:"%02X",$0) }.joined() }
    static func big(_ value: UInt64, count: Int) -> Data { Data((0..<count).reversed().map { UInt8(truncatingIfNeeded:value >> ($0*8)) }) }
    public static func bytes(_ plan: XrplSendPlan, publicKey: Data, signature: Data? = nil) throws -> Data {
        try plan.validate(checkAge:false)
        if plan.tokenAuthorization == true { return try XrplTokenAuthorization.bytes(plan,publicKey:publicKey) }
        if let setup = plan.multisigSetup, let policy = plan.multisig { return try setup.bytes(plan: plan, policy: policy, publicKey: publicKey, signature: signature) }
        guard (publicKey.count == 33 || (publicKey.isEmpty && plan.multisig != nil)), signature == nil || (8...72).contains(signature!.count) else { throw XrplSendError.signing }
        var out = Data([0x12,0,plan.closesAccount ? 21:0,0x22])+big(0x80000000,count:4)+Data([0x24])+big(UInt64(plan.sequence),count:4)
        if let tag = plan.destinationTag { out += Data([0x2e])+big(UInt64(tag),count:4) }
        out += Data([0x20,0x1b])+big(UInt64(plan.lastLedger),count:4)
        if !plan.closesAccount { out += Data([0x61])+(try amount(reference:plan.reference,atomic:plan.amount)) }
        out += Data([0x68])+big(plan.fee | 0x4000000000000000,count:8)
        if plan.reference != "native" { out += Data([0x69])+(try amount(reference:plan.reference,atomic:plan.assetDebit)) }
        out += Data([0x73,UInt8(publicKey.count)])+publicKey
        if let signature { out += Data([0x74,UInt8(signature.count)])+signature }
        out += Data([0x81,20])+(try XrplIdentity.accountBytes(plan.sender))
        out += Data([0x83,20])+(try XrplIdentity.accountBytes(plan.recipient))
        return out
    }
    static func amount(reference: String, atomic: String) throws -> Data {
        if reference == "native" { guard let n = UInt64(atomic) else { throw XrplSendError.amount }; return big(n | 0x4000000000000000,count:8) }
        guard let dot = reference.lastIndex(of:".") else {
            guard let n = UInt64(atomic), n <= UInt64(Int64.max) else { throw XrplSendError.amount }
            return Data([0x60])+big(n,count:8)+(try TronIdentity.hex(reference))
        }
        let currency = String(reference[..<dot]), issuer = String(reference[reference.index(after:dot)...])
        let c: Data
        if currency.utf8.count == 3 { c = Data(repeating:0,count:12)+Data(currency.utf8)+Data(repeating:0,count:5) }
        else { c = try TronIdentity.hex(currency) }
        let value = try XrplSendAmount.issuedValue(atomic)
        var bits: UInt64 = 0x8000000000000000
        if value != "0" {
            let parts = value.split(separator:"e"), digits = String(parts[0])
            let exponent = Int(parts[1])!-(16-digits.count)
            let mantissa = UInt64(digits+String(repeating:"0",count:16-digits.count))!
            bits |= 0x4000000000000000 | (UInt64(exponent+97)<<54) | mantissa
        }
        return big(bits,count:8)+c+(try XrplIdentity.accountBytes(issuer))
    }
}

/// RIPEMD-160 (ISO/IEC 10118-3) for classic account identifiers only. No secret
/// material is hashed here. Known-answer and independent SDK vectors cover it.
enum XrplRIPEMD160 {
    static func hash(_ data: Data) -> Data {
        let r = [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,7,4,13,1,10,6,15,3,12,0,9,5,2,14,11,8,3,10,14,4,9,15,8,1,2,7,0,6,13,11,5,12,1,9,11,10,0,8,12,4,13,3,7,15,14,5,6,2,4,0,5,9,7,12,2,10,14,1,3,8,11,6,15,13]
        let rr = [5,14,7,0,9,2,11,4,13,6,15,8,1,10,3,12,6,11,3,7,0,13,5,10,14,15,8,12,4,9,1,2,15,5,1,3,7,14,6,9,11,8,12,2,10,0,4,13,8,6,4,1,3,11,15,0,5,12,2,13,9,7,10,14,12,15,10,4,1,5,8,7,6,2,13,14,0,3,9,11]
        let s = [11,14,15,12,5,8,7,9,11,13,14,15,6,7,9,8,7,6,8,13,11,9,7,15,7,12,15,9,11,7,13,12,11,13,6,7,14,9,13,15,14,8,13,6,5,12,7,5,11,12,14,15,14,15,9,8,9,14,5,6,8,6,5,12,9,15,5,11,6,8,13,12,5,12,13,14,11,8,5,6]
        let ss = [8,9,9,11,13,15,15,5,7,7,8,11,14,14,12,6,9,13,15,7,12,8,9,11,7,7,12,7,6,15,13,11,9,7,15,11,8,6,6,14,12,13,5,14,13,13,7,5,15,5,8,11,14,14,6,14,6,9,12,9,12,5,15,8,8,5,12,9,12,5,14,6,8,13,6,5,15,13,11,11]
        let k: [UInt32] = [0,0x5a827999,0x6ed9eba1,0x8f1bbcdc,0xa953fd4e]
        let kk: [UInt32] = [0x50a28be6,0x5c4dd124,0x6d703ef3,0x7a6d76e9,0]
        func rol(_ x: UInt32, _ n: Int) -> UInt32 { (x<<n)|(x>>(32-n)) }
        func f(_ j: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
            switch j { case 0: x^y^z; case 1: (x&y)|(~x&z); case 2: (x | ~y)^z; case 3: (x&z)|(y & ~z); default: x^(y | ~z) }
        }
        var bytes = Array(data), h: [UInt32] = [0x67452301,0xefcdab89,0x98badcfe,0x10325476,0xc3d2e1f0]
        let bitCount = UInt64(bytes.count)*8
        bytes.append(0x80); while bytes.count%64 != 56 { bytes.append(0) }
        bytes += (0..<8).map { UInt8(truncatingIfNeeded:bitCount >> ($0*8)) }
        for start in stride(from:0,to:bytes.count,by:64) {
            var x = [UInt32](repeating:0,count:16)
            for i in 0..<16 { for j in 0..<4 { x[i] |= UInt32(bytes[start+i*4+j]) << (j*8) } }
            var a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],aa=a,bb=b,cc=c,dd=d,ee=e
            for j in 0..<80 {
                let t = rol(a &+ f(j/16,b,c,d) &+ x[r[j]] &+ k[j/16],s[j]) &+ e
                a=e;e=d;d=rol(c,10);c=b;b=t
                let tt = rol(aa &+ f(4-j/16,bb,cc,dd) &+ x[rr[j]] &+ kk[j/16],ss[j]) &+ ee
                aa=ee;ee=dd;dd=rol(cc,10);cc=bb;bb=tt
            }
            let t=h[1] &+ c &+ dd; h[1]=h[2] &+ d &+ ee; h[2]=h[3] &+ e &+ aa
            h[3]=h[4] &+ a &+ bb; h[4]=h[0] &+ b &+ cc; h[0]=t
        }
        return Data(h.flatMap { n in (0..<4).map { UInt8(truncatingIfNeeded:n >> ($0*8)) } })
    }
}

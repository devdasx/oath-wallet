import Foundation
import CryptoKit

public enum TonSendCrypto {
    public static func publicKey(privateKey:Data) throws -> Data { try Curve25519.Signing.PrivateKey(rawRepresentation:privateKey).publicKey.rawRepresentation }
    public static func address(publicKey:Data) throws -> String { "0:"+TronSendCrypto.hex(try stateInit(publicKey).hash) }
    static func code() throws -> TonCell {
        guard let url=Bundle.module.url(forResource:"TonWalletV4R2",withExtension:"b64"),let bytes=Data(base64Encoded:try String(contentsOf:url,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)) else { throw TonSendError.configuration }
        let cell=try TonCell.parse(bytes)
        guard TronSendCrypto.hex(cell.hash)=="feb5ff6820e2ff0d9483e7e0d62c817d846789fb4ae580c878866d959dabd5c0" else { throw TonSendError.signing };return cell
    }
    static func stateInit(_ publicKey:Data) throws -> TonCell {
        guard publicKey.count==32 else { throw TonSendError.signing }
        var data=TonBuilder();try data.uint(0,32);try data.uint(TonSendPlan.walletID,32);try data.bytes(publicKey);try data.uint(0,1)
        var initCell=TonBuilder();try initCell.uint(6,5);try initCell.ref(code());try initCell.ref(data.cell());return try initCell.cell()
    }
    static func comment(_ text:String) throws -> TonCell {
        var b=TonBuilder();if !text.isEmpty { try b.uint(0,32);try b.bytes(Data(text.utf8)) };return try b.cell()
    }
    static func transferBody(_ p:TonSendPlan) throws -> TonCell {
        if p.reference=="native" { return try comment(p.memo) }
        var b=TonBuilder();try b.uint(0x0f8a7ea5,32);try b.uint(p.queryID,64);try b.jettonCoins(p.amount)
        try b.address(p.recipient);try b.address(p.sender);try b.uint(0,1);try b.coins(1)
        try b.uint(1,1);try b.ref(comment(p.memo));return try b.cell()
    }
    static func internalMessage(_ p:TonSendPlan) throws -> TonCell {
        var b=TonBuilder();try b.uint(p.bounce ? 0x18:0x10,6) // internal, ihr disabled, bounce, not bounced, no source
        try b.address(p.jettonWallet ?? p.recipient);try b.coins(p.attached)
        try b.uint(0,1);try b.coins(0);try b.coins(0);try b.uint(0,64);try b.uint(0,32);try b.uint(0,1)
        let body=try transferBody(p)
        if b.bits.count+1+body.bits.count<=1023 { try b.uint(0,1);try b.inline(body) }
        else { try b.uint(1,1);try b.ref(body) }
        return try b.cell()
    }
    static func signingCell(_ p:TonSendPlan) throws -> TonCell {
        var b=TonBuilder();try b.uint(TonSendPlan.walletID,32);try b.uint(UInt64(p.expiration),32);try b.uint(UInt64(p.sequence),32)
        try b.uint(0,8);try b.uint(3,8);try b.ref(internalMessage(p));return try b.cell()
    }
    static func body(_ p:TonSendPlan,_ signature:Data) throws -> TonCell {
        guard signature.count==64 else { throw TonSendError.signing }
        var b=TonBuilder();try b.bytes(signature);try b.inline(signingCell(p));return try b.cell()
    }
    static func external(_ p:TonSendPlan,_ body:TonCell,normalized:Bool=false) throws -> TonCell {
        var b=TonBuilder();try b.uint(2,2);try b.uint(0,2);try b.address(p.sender);try b.coins(0)
        if p.deploy && !normalized { try b.uint(1,1);try b.uint(1,1);try b.ref(stateInit(p.publicKey)) }
        else { try b.uint(0,1) }
        // TEP-467 canonical external message always has a referenced body and no init.
        try b.uint(1,1);try b.ref(body);return try b.cell()
    }
    public static func unsigned(_ plan:TonSendPlan) throws -> Data { try external(plan,body(plan,Data(repeating:0,count:64))).boc() }
    public static func sign(_ plan:TonSendPlan,privateKey:Data,now:Date = .now) throws -> TonSignedSend {
        try plan.validate(now:now)
        let key=try Curve25519.Signing.PrivateKey(rawRepresentation:privateKey)
        guard key.publicKey.rawRepresentation==plan.publicKey else { throw TonSendError.signing }
        let sig=try key.signature(for:signingCell(plan).hash),body=try body(plan,sig)
        return .init(bytes:try external(plan,body).boc(),signature:sig,hash:TronSendCrypto.hex(try external(plan,body,normalized:true).hash),bodyHash:TronSendCrypto.hex(body.hash))
    }
    public static func verify(_ signed:TonSignedSend,plan:TonSendPlan) throws {
        try plan.validate(checkAge:false)
        let body=try body(plan,signed.signature)
        guard try Curve25519.Signing.PublicKey(rawRepresentation:plan.publicKey).isValidSignature(signed.signature,for:signingCell(plan).hash),
              signed.bytes == (try external(plan,body).boc()),signed.hash == (try TronSendCrypto.hex(external(plan,body,normalized:true).hash)),
              signed.bodyHash==TronSendCrypto.hex(body.hash) else { throw TonSendError.signing }
    }
}

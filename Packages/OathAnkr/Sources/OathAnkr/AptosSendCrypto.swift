import Foundation
import CryptoKit

public enum AptosSendCrypto {
    public static func publicKey(privateKey:Data) throws -> Data { try Curve25519.Signing.PrivateKey(rawRepresentation:privateKey).publicKey.rawRepresentation }
    public static func address(privateKey:Data) throws -> String { try address(publicKey:publicKey(privateKey:privateKey)) }
    public static func address(publicKey:Data) throws -> String {
        guard publicKey.count==32 else { throw AptosSendError.signing }
        return "0x"+TronSendCrypto.hex(TronSendCrypto.sha3(publicKey+Data([0])))
    }
    public static func sign(_ plan:AptosSendPlan,privateKey:Data,now:Date = .now) throws -> AptosSignedSend {
        try plan.validate(now:now)
        let key=try Curve25519.Signing.PrivateKey(rawRepresentation:privateKey)
        guard key.publicKey.rawRepresentation==plan.publicKey else { throw AptosSendError.signing }
        let raw=try raw(plan),signature=try key.signature(for:signingMessage(raw))
        let bytes=raw+authenticator(publicKey:plan.publicKey,signature:signature)
        return .init(bytes:bytes,publicKey:plan.publicKey,signature:signature,hash:hash(bytes))
    }
    public static func verify(_ signed:AptosSignedSend,plan:AptosSendPlan) throws {
        try plan.validate(checkAge:false)
        let raw=try raw(plan)
        guard signed.publicKey==plan.publicKey,signed.signature.count==64,
              signed.bytes==raw+authenticator(publicKey:plan.publicKey,signature:signed.signature),signed.hash==hash(signed.bytes),
              try Curve25519.Signing.PublicKey(rawRepresentation:plan.publicKey).isValidSignature(signed.signature,for:signingMessage(raw)) else { throw AptosSendError.signing }
    }
    static func signingMessage(_ raw:Data) -> Data { TronSendCrypto.sha3(Data("APTOS::RawTransaction".utf8))+raw }
    public static func hash(_ bytes:Data) -> String { "0x"+TronSendCrypto.hex(TronSendCrypto.sha3(TronSendCrypto.sha3(Data("APTOS::Transaction".utf8))+Data([0])+bytes)) }
    static func authenticator(publicKey:Data,signature:Data) -> Data { Data([0])+AptosBCS.vector(publicKey)+AptosBCS.vector(signature) }
    public static func raw(_ p:AptosSendPlan) throws -> Data {
        let function:String,types:[String],args:[Data]
        if p.reference == "native" { function="aptos_account::transfer";types=[];args=[try AptosBCS.address(p.recipient),AptosBCS.u64(p.amount)] }
        else if p.reference.contains("::") { function="aptos_account::transfer_coins";types=[p.reference];args=[try AptosBCS.address(p.recipient),AptosBCS.u64(p.amount)] }
        else { function="primary_fungible_store::transfer_assert_minimum_deposit";types=["0x1::fungible_asset::Metadata"];args=[try AptosBCS.address(p.reference),try AptosBCS.address(p.recipient),AptosBCS.u64(p.amount),AptosBCS.u64(p.amount)] }
        let parts=function.components(separatedBy:"::")
        var payload=Data([2])+AptosBCS.addressOne+AptosBCS.vector(Data(parts[0].utf8))+AptosBCS.vector(Data(parts[1].utf8))+AptosBCS.uleb(types.count)
        for type in types { payload += try AptosBCS.typeTag(type) }
        payload += AptosBCS.uleb(args.count)
        for arg in args { payload += AptosBCS.vector(arg) }
        return try AptosBCS.address(p.sender)+AptosBCS.u64(p.sequence)+payload+AptosBCS.u64(p.maxGasAmount)+AptosBCS.u64(p.gasUnitPrice)+AptosBCS.u64(p.expiration)+Data([p.network.chainID])
    }
    static func payload(_ p:AptosSendPlan) -> AptosJSON {
        let function:String,types:[String],args:[String]
        if p.reference=="native" { function="0x1::aptos_account::transfer";types=[];args=[p.recipient,String(p.amount)] }
        else if p.reference.contains("::") { function="0x1::aptos_account::transfer_coins";types=[p.reference];args=[p.recipient,String(p.amount)] }
        else { function="0x1::primary_fungible_store::transfer_assert_minimum_deposit";types=["0x1::fungible_asset::Metadata"];args=[p.reference,p.recipient,String(p.amount),String(p.amount)] }
        return .object(["type":.string("entry_function_payload"),"function":.string(function),"type_arguments":.array(types.map(AptosJSON.string)),"arguments":.array(args.map(AptosJSON.string))])
    }
}
/// Bounded Move type-tag parser; generic Coin types are serialized, never interpolated as executable code.
enum AptosBCS {
    static let addressOne=Data(repeating:0,count:31)+Data([1])
    static func address(_ value:String) throws -> Data { try TronIdentity.hex(AptosIdentity.address(value)) }
    static func u64(_ n:UInt64) -> Data { Data((0..<8).map { UInt8(truncatingIfNeeded:n>>($0*8)) }) }
    static func uleb(_ count:Int) -> Data { TronSendCrypto.varint(UInt64(count)) }
    static func vector(_ data:Data) -> Data { uleb(data.count)+data }
    static func typeTag(_ text:String,depth:Int=0) throws -> Data {
        guard depth<16,text.count<=4096,!text.isEmpty else { throw AptosSendError.malformed }
        let primitive:[String:UInt8]=["bool":0,"u8":1,"u64":2,"u128":3,"address":4,"signer":5,"u16":8,"u32":9,"u256":10]
        if let n=primitive[text] { return Data([n]) }
        if text.hasPrefix("vector<"),text.hasSuffix(">") { return Data([6])+(try typeTag(String(text.dropFirst(7).dropLast()),depth:depth+1)) }
        let head=String(text.prefix(while:{$0 != "<"})),parts=head.components(separatedBy:"::")
        guard parts.count==3,parts.dropFirst().allSatisfy({$0.range(of:"^[A-Za-z_][A-Za-z0-9_]*$",options:.regularExpression) != nil}) else { throw AptosSendError.malformed }
        var types=[String]()
        if head.count<text.count {
            guard text.last==">" else { throw AptosSendError.malformed }
            var nesting=0,current=""
            for c in text.dropFirst(head.count+1).dropLast() {
                if c=="," && nesting==0 { types.append(current);current="";continue }
                if c=="<" { nesting+=1 }; if c==">" { nesting-=1 };guard nesting>=0 else { throw AptosSendError.malformed };current.append(c)
            }
            guard nesting==0,!current.isEmpty else { throw AptosSendError.malformed };types.append(current)
        }
        var data=Data([7])+(try address(parts[0]))+vector(Data(parts[1].utf8))+vector(Data(parts[2].utf8))+uleb(types.count)
        for t in types { data += try typeTag(t,depth:depth+1) };return data
    }
}

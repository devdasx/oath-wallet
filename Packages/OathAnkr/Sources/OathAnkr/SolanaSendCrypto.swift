import Foundation
import CryptoKit

public enum SolanaSendCrypto {
    public static let system="11111111111111111111111111111111"
    public static let associated="ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL"
    static let budget="ComputeBudget111111111111111111111111111111"
    static let memoProgram="MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr"
    public static func publicKey(privateKey:Data) throws -> Data { try Curve25519.Signing.PrivateKey(rawRepresentation:privateKey).publicKey.rawRepresentation }
    public static func address(privateKey:Data) throws -> String { encode(try publicKey(privateKey:privateKey)) }
    public static func encode(_ bytes:Data) -> String { SuiSendCrypto.base58(bytes) }
    public static func decode(_ text:String) throws -> Data {
        guard !text.isEmpty,text.utf8.count<=88 else { throw SolanaSendError.malformed }
        let alphabet=Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
        var bytes=[Int]()
        for c in text.utf8 {
            guard let n=alphabet.firstIndex(of:c) else { throw SolanaSendError.malformed }
            var carry=n
            for i in bytes.indices { carry+=bytes[i]*58;bytes[i]=carry&255;carry>>=8 }
            while carry>0 { bytes.append(carry&255);carry>>=8 }
        }
        return Data(Array(repeating:UInt8(0),count:text.utf8.prefix(while:{$0==49}).count)+bytes.reversed().map(UInt8.init))
    }
    public static func associatedAddress(owner:String,mint:String,program:String) throws -> String {
        guard [SolanaIdentity.tokenProgram,SolanaIdentity.token2022Program].contains(program),
              SolanaIdentity.isAddress(owner),SolanaIdentity.isAddress(mint) else { throw SolanaSendError.malformed }
        let seeds=try decode(owner)+decode(program)+decode(mint),id=try decode(associated)
        for bump in (0...255).reversed() {
            let hash=Data(SHA256.hash(data:seeds+Data([UInt8(bump)])+id+Data("ProgramDerivedAddress".utf8)))
            if !SolanaCurve.isPoint(hash) { return encode(hash) }
        }
        throw SolanaSendError.malformed
    }
    public static func sign(_ plan:SolanaSendPlan,privateKey:Data) throws -> SolanaSignedSend {
        try plan.validate()
        let key=try Curve25519.Signing.PrivateKey(rawRepresentation:privateKey),pub=key.publicKey.rawRepresentation
        guard encode(pub)==plan.sender else { throw SolanaSendError.wrongOwner }
        let message=try message(plan),sig=try key.signature(for:message)
        let signed=SolanaSignedSend(bytes:Data([1])+sig+message,publicKey:pub,signature:sig,hash:encode(sig))
        try verify(signed,plan:plan);return signed
    }
    public static func verify(_ signed:SolanaSignedSend,plan:SolanaSendPlan) throws {
        try plan.validate(checkAge:false)
        let message=try message(plan)
        guard signed.publicKey.count==32,encode(signed.publicKey)==plan.sender,signed.signature.count==64,
              signed.hash==encode(signed.signature),signed.bytes==Data([1])+signed.signature+message,
              try Curve25519.Signing.PublicKey(rawRepresentation:signed.publicKey).isValidSignature(signed.signature,for:message) else { throw SolanaSendError.signing }
    }
    struct Instruction { let program:String,keys:[(String,Bool)],data:Data }
    static func le<T:FixedWidthInteger>(_ n:T) -> Data { withUnsafeBytes(of:n.littleEndian) { Data($0) } }
    static func short(_ n:Int) -> Data {
        var n=n,result=Data()
        repeat { let b=UInt8(n&127);n>>=7;result.append(b | (n>0 ? 128:0)) } while n>0
        return result
    }
    public static func message(_ p:SolanaSendPlan) throws -> Data {
        try p.validate(checkAge:false)
        var instructions=[Instruction(program:budget,keys:[],data:Data([2])+le(p.computeUnits)),
                          Instruction(program:budget,keys:[],data:Data([3])+le(p.microLamports))]
        func memo() { if !p.memo.isEmpty { instructions.append(.init(program:memoProgram,keys:[(p.sender,false)],data:Data(p.memo.utf8))) } }
        if let removal=p.removal {
            instructions.append(.init(program:removal.program,keys:[(removal.account,true),(p.sender,false)],data:Data([5])))
        } else if p.reference=="native" {
            memo();instructions.append(.init(program:system,keys:[(p.sender,true),(p.recipient,true)],data:le(UInt32(2))+le(p.amount)))
        } else {
            let destination=try associatedAddress(owner:p.recipient,mint:p.reference,program:p.program)
            instructions.append(.init(program:associated,keys:[(p.sender,true),(destination,true),(p.recipient,false),(p.reference,false),(system,false),(p.program,false)],data:Data([1])))
            for (i,source) in p.sources.enumerated() {
                memo()
                let data = p.tokenFees.isEmpty ? Data([12])+le(source.amount)+Data([UInt8(p.decimals)]) : Data([26,1])+le(source.amount)+Data([UInt8(p.decimals)])+le(p.tokenFees[i])
                instructions.append(.init(program:p.program,keys:[(source.address,true),(p.reference,false),(destination,true),(p.sender,false)],data:data))
            }
        }
        var ordered=[p.sender],writable:Set<String>=[p.sender]
        for ix in instructions {
            if !ordered.contains(ix.program) { ordered.append(ix.program) }
            for (key,write) in ix.keys { if !ordered.contains(key) { ordered.append(key) };if write { writable.insert(key) } }
        }
        let keys=[p.sender]+ordered.dropFirst().filter(writable.contains)+ordered.dropFirst().filter { !writable.contains($0) }
        guard keys.count<256 else { throw SolanaSendError.malformed }
        var result=Data([1,0,UInt8(keys.filter { !writable.contains($0) }.count)])+short(keys.count)
        for key in keys { let bytes=try decode(key);guard bytes.count==32 else { throw SolanaSendError.malformed };result+=bytes }
        result += try decode(p.blockhash);result+=short(instructions.count)
        for ix in instructions {
            result.append(UInt8(keys.firstIndex(of:ix.program)!));result+=short(ix.keys.count)
            result+=Data(ix.keys.map { UInt8(keys.firstIndex(of:$0.0)!) });result+=short(ix.data.count);result+=ix.data
        }
        guard result.count+65<=1232 else { throw SolanaSendError.amount }
        return result
    }
}

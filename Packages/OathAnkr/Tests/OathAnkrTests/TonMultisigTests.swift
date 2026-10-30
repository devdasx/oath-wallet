import XCTest
@testable import OathAnkr

final class TonMultisigTests: XCTestCase {
    struct Vector: Decodable { let network:TonSendNetwork; let envelope:TonMultisigCrypto.Envelope; let body:String; let payload:String; let n:Int,k:Int,token:Bool,sender:String,recipient:String,bodyHash:String,hash:String }
    func testSDKMatrixAndRecoveryOfSignedPayload() throws {
        let url = Bundle.module.url(forResource:"vectors",withExtension:"json",subdirectory:"Fixtures/TonMultisig")!
        let vectors = try JSONDecoder().decode([Vector].self,from:Data(contentsOf:url))
        for v in vectors {
            let keys = (1...v.n).map { Data(repeating:UInt8($0),count:32) }
            let policy = try TonMultisigPolicy(required:v.k,publicKeys:keys.map(TonSendCrypto.publicKey))
            XCTAssertEqual(try policy.address(network:v.network),v.sender)
            XCTAssertNotEqual(try policy.address(network:v.network == .mainnet ? .testnet:.mainnet),v.sender)
            let p = TonSendPlan(network:v.network,sender:v.sender,recipient:v.recipient,reference:v.token ? v.recipient:"native",publicKey:policy.publicKeys[0],decimals:9,
                requestedAmount:123456,amount:123456,assetBalance:1_000_000_000,nativeBalance:1_000_000_000,sequence:0,expiration:2_000_003_900,deploy:true,bounce:v.token,
                fee:1000000,feeReserve:2000000,attached:v.token ? 150000000:123456,jettonWallet:v.token ? v.recipient:nil,recipientJettonWallet:v.token ? v.recipient:nil,
                queryID:(UInt64(2_000_003_900)<<32)|42,createdAt:Date(timeIntervalSince1970:2_000_000_000),multisig:policy)
            let signed = try TonMultisigCrypto.sign(p,privateKeys:keys,now:p.createdAt)
            XCTAssertEqual(try TonMultisigCrypto.payload(p).hash, try TonCell.parse(Data(base64Encoded:v.payload)!).hash)
            let sdkBody = try TonCell.parse(Data(base64Encoded:v.body)!)
            let sdkSigned = TonSignedSend(bytes:try TonSendCrypto.external(p,sdkBody).boc(),signature:try JSONEncoder().encode(v.envelope),hash:v.hash,bodyHash:v.bodyHash)
            try TonSendCrypto.verify(sdkSigned,plan:p)
            // CryptoKit may randomize Ed25519 nonces; validate signatures, not byte equality.
            if let folder = ProcessInfo.processInfo.environment["OATH_TON_VECTOR_EXPORT"] {
                struct Export:Encodable { let network:TonSendNetwork,n:Int,k:Int,token:Bool,bytes:Data }
                try JSONEncoder().encode(Export(network:v.network,n:v.n,k:v.k,token:v.token,bytes:signed.bytes)).write(to:URL(fileURLWithPath:folder).appendingPathComponent("\(v.network.rawValue)-\(v.n)-\(v.k)-\(v.token).json"))
            }
            try TonSendCrypto.verify(signed,plan:p)
            let restored = try JSONDecoder().decode(TonSendPlan.self,from:JSONEncoder().encode(p))
            try TonSendCrypto.verify(JSONDecoder().decode(TonSignedSend.self,from:JSONEncoder().encode(signed)),plan:restored)
            XCTAssertThrowsError(try TonMultisigCrypto.sign(p,privateKeys:Array(keys.prefix(v.k-1)),now:p.createdAt))
            XCTAssertThrowsError(try TonMultisigCrypto.sign(p,privateKeys:[keys[0],keys[0]],now:p.createdAt))
            var bytes = signed.bytes; bytes[bytes.count-1] ^= 1
            XCTAssertThrowsError(try TonSendCrypto.verify(.init(bytes:bytes,signature:signed.signature,hash:signed.hash,bodyHash:signed.bodyHash),plan:p))
            var envelope = try JSONDecoder().decode([String:TonJSON].self,from:signed.signature)
            envelope["root"] = .number("7")
            XCTAssertThrowsError(try TonSendCrypto.verify(.init(bytes:signed.bytes,signature:JSONEncoder().encode(envelope),hash:signed.hash,bodyHash:signed.bodyHash),plan:p))
            let initial = try policy.stateInit(v.network)
            try policy.validateState(code:initial.refs[0],data:initial.refs[1],network:v.network)
            XCTAssertThrowsError(try policy.validateState(code:initial.refs[0],data:initial.refs[1],network:v.network == .mainnet ? .testnet:.mainnet))
        }
    }
    func testRejectsInvalidPolicyAndForgedDecodedOrdering() throws {
        let a=Data(repeating:1,count:32),b=Data(repeating:2,count:32)
        for (k,keys) in [(0,[a,b]),(3,[a,b]),(2,[a,a]),(1,[a]),(1,[Data([1]),b])] {
            XCTAssertThrowsError(try TonMultisigPolicy(required:k,publicKeys:keys))
        }
        let raw = try JSONSerialization.data(withJSONObject:["required":2,"publicKeys":[b.base64EncodedString(),a.base64EncodedString()]])
        XCTAssertThrowsError(try JSONDecoder().decode(TonMultisigPolicy.self,from:raw).validate())
    }
    func testReplayStateCannotReleaseAcceptedOrGarbageCollectedQueries() throws {
        let p = try TonMultisigPolicy(required:2,publicKeys:[1,2].map { try TonSendCrypto.publicKey(privateKey:Data(repeating:$0,count:32)) })
        func state(cleaned:UInt64,query:UInt64?) throws -> TonCell {
            var b=TonBuilder();try b.uint(TonMultisigPolicy.walletID(.testnet),32);try b.uint(2,8);try b.uint(2,8)
            try b.uint(cleaned,64);try b.uint(1,1);try b.ref(p.owners());try b.uint(query == nil ? 0:1,1)
            if let query {
                // A single long-label Hashmap(64) replay entry.
                var entry=TonBuilder();try entry.uint(2,2);try entry.uint(64,7);try entry.uint(query,64);try entry.uint(1,1)
                try b.ref(entry.cell())
            }
            return try b.cell()
        }
        XCTAssertTrue(try TonMultisigPolicy.queryWasNeverAccepted(42,data:state(cleaned:0,query:nil)))
        XCTAssertFalse(try TonMultisigPolicy.queryWasNeverAccepted(42,data:state(cleaned:0,query:42)))
        XCTAssertTrue(try TonMultisigPolicy.queryWasNeverAccepted(43,data:state(cleaned:0,query:42)))
        XCTAssertFalse(try TonMultisigPolicy.queryWasNeverAccepted(42,data:state(cleaned:42,query:nil)))
        XCTAssertFalse(try TonMultisigPolicy.queryWasNeverAccepted(42,data:state(cleaned:100,query:nil)))
        XCTAssertFalse(try TonMultisigPolicy.queryWasNeverAccepted(UInt64.max,data:state(cleaned:0,query:UInt64.max)))
        XCTAssertThrowsError(try TonMultisigPolicy.queryWasNeverAccepted(42,data:TonCell([])))
        XCTAssertThrowsError(try p.validateState(code:TonCell([]),data:state(cleaned:0,query:nil),network:.testnet))
    }
}

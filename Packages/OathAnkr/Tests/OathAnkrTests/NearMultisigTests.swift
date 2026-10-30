import XCTest
import CryptoKit
@testable import OathAnkr

final class NearMultisigTests: XCTestCase {
    func fixture(required:Int=2,count:Int=3,stage:NearMultisigContext.Stage = .transfer,token:Bool=false) throws -> (NearSendPlan,[Data]) {
        let bootstrap=Data(repeating:99,count:32)
        let keys=try (1...count).map { Data(repeating:UInt8($0),count:32) }.sorted { try NearSendCrypto.publicKey(privateKey:$0).lexicographicallyPrecedes(NearSendCrypto.publicKey(privateKey:$1)) }
        let policy=try NearMultisigPolicy(bootstrap:NearSendCrypto.publicKey(privateKey:bootstrap),required:required,publicKeys:keys.map { try NearSendCrypto.publicKey(privateKey:$0) })
        let context=NearMultisigContext(policy:policy,stage:stage,requestID:5,nonces:Array(repeating:100,count:stage == .transfer ? required:1))
        let p=NearSendPlan(network:.testnet,sender:policy.address,recipient:stage == .transfer ? "receiver.testnet":policy.address,reference:token ? "wrap.testnet":"native",publicKey:stage == .transfer ? policy.publicKeys[0]:policy.bootstrap,decimals:24,requestedAmount:"1",amount:"1",assetBalance:"10000000000000000000000000",nativeBalance:"10000000000000000000000000",reserve:"4000000000000000000000000",storageDeposit:token ? "1250000000000000000000":"0",fee:"100000000000000000000000",gasPriceCeiling:"200000000",gas:token ? 50_000_000_000_000:0,storageGas:token ? 30_000_000_000_000:0,nonce:100,blockHash:SuiSendCrypto.base58(Data(repeating:3,count:32)),blockHeight:1,validityPeriod:86400,multisig:context)
        return (p,stage == .transfer ? Array(keys.prefix(required)):[bootstrap])
    }
    func testAllThresholdSizesAndStagesSignVerifyRoundtrip() throws {
        for (required,count) in [(1,2),(2,3),(3,5),(7,10),(10,10)] {
            for stage:NearMultisigContext.Stage in [.deploy,.secure,.transfer] {
                let (p,keys)=try fixture(required:required,count:count,stage:stage)
                let signed=try NearSendCrypto.sign(p,privateKeys:keys)
                XCTAssertEqual(signed.multisigParts?.count,stage == .transfer ? required+1:1)
                XCTAssertNoThrow(try NearSendCrypto.verify(signed,plan:p))
                let decoded=try JSONDecoder().decode(NearSignedSend.self,from:JSONEncoder().encode(signed))
                XCTAssertEqual(decoded,signed)
            }
        }
    }
    func testPolicyRejectsInvalidQuorumDuplicatesAndBootstrapMember() throws {
        let (p,_)=try fixture(),c=p.multisig!.policy
        for required in [0,4] { XCTAssertThrowsError(try NearMultisigPolicy(bootstrap:c.bootstrap,required:required,publicKeys:c.publicKeys)) }
        XCTAssertThrowsError(try NearMultisigPolicy(bootstrap:c.bootstrap,required:1,publicKeys:[c.publicKeys[0],c.publicKeys[0]]))
        XCTAssertThrowsError(try NearMultisigPolicy(bootstrap:c.bootstrap,required:1,publicKeys:[c.bootstrap,c.publicKeys[0]]))
        XCTAssertThrowsError(try fixture(required:2,count:11))
    }
    func testMissingDuplicateForeignAndScalarSignaturesCannotAuthorize() throws {
        let (p,keys)=try fixture()
        XCTAssertThrowsError(try NearSendCrypto.sign(p,privateKeys:[keys[0]]))
        XCTAssertThrowsError(try NearSendCrypto.sign(p,privateKeys:[keys[0],keys[0]]))
        XCTAssertThrowsError(try NearSendCrypto.sign(p,privateKeys:[keys[0],Data(repeating:90,count:32)]))
        XCTAssertThrowsError(try NearSendCrypto.sign(p,privateKey:keys[0]))
        let signed=try NearSendCrypto.sign(p,privateKeys:keys)
        let scalar=NearSignedSend(bytes:signed.bytes,publicKey:signed.publicKey,signature:signed.signature,hash:signed.hash)
        XCTAssertThrowsError(try NearSendCrypto.verify(scalar,plan:p))
    }
    func testIntentAndPolicyTamperingAndPartReorderingRejected() throws {
        let (p,keys)=try fixture(),s=try NearSendCrypto.sign(p,privateKeys:keys)
        for change:[String:Any] in [["recipient":"attacker.testnet"],["amount":"2"],["blockHash":SuiSendCrypto.base58(Data(repeating:4,count:32))],["nonce":101]] {
            XCTAssertThrowsError(try NearSendCrypto.verify(s,plan:NearSendTests.changing(p,change)))
        }
        var parts=s.multisigParts!;parts.swapAt(0,1)
        let changed=NearSignedSend(bytes:s.bytes,publicKey:s.publicKey,signature:s.signature,hash:s.hash,multisigParts:parts)
        XCTAssertThrowsError(try NearSendCrypto.verify(changed,plan:p))
        var j=try JSONSerialization.jsonObject(with:JSONEncoder().encode(p)) as! [String:Any]
        var c=j["multisig"] as! [String:Any];c["requestID"]=6;j["multisig"]=c
        let altered=try JSONDecoder().decode(NearSendPlan.self,from:JSONSerialization.data(withJSONObject:j))
        XCTAssertThrowsError(try NearSendCrypto.verify(s,plan:altered))
    }
    func testTokenActionsPreserveRegistrationDepositAndExactAmount() throws {
        let (p,keys)=try fixture(token:true),request=try p.multisig!.request(p)
        XCTAssertEqual(request["receiver_id"].string,"wrap.testnet")
        let actions=request["actions"].array!
        XCTAssertEqual(actions.count,2);XCTAssertEqual(actions[0]["method_name"].string,"storage_deposit")
        XCTAssertEqual(actions[0]["deposit"].string,p.storageDeposit)
        XCTAssertEqual(actions[1]["method_name"].string,"ft_transfer");XCTAssertEqual(actions[1]["deposit"].string,"1")
        let signed=try NearSendCrypto.sign(p,privateKeys:keys)
        XCTAssertNoThrow(try NearSendCrypto.verify(signed,plan:p))
    }
    func testPinnedContractDigestAndFreshBootstrap() throws {
        XCTAssertEqual(TronSendCrypto.hex(Data(SHA256.hash(data:try NearMultisigPolicy.code()))),NearMultisigPolicy.codeSHA256)
        let a=NearMultisigPolicy.freshBootstrapSeed(),b=NearMultisigPolicy.freshBootstrapSeed()
        XCTAssertEqual(a.count,32);XCTAssertNotEqual(a,b)
    }
}

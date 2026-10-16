import XCTest
import CryptoKit
@testable import OathAnkr

final class NearSendTests:XCTestCase,@unchecked Sendable {
    static let seed=Data(0..<32), sender="sender.testnet",recipient="recipient.testnet"
    static func fixture(_ name:String) throws -> Data { try Data(contentsOf:Bundle.module.url(forResource:name,withExtension:"json",subdirectory:"Fixtures/NearSend")!) }
    static func plan(token:Bool=false) throws -> NearSendPlan {
        .init(network:.testnet,sender:sender,recipient:recipient,reference:token ? "wrap.testnet":"native",publicKey:try NearSendCrypto.publicKey(privateKey:seed),decimals:24,
              requestedAmount:"100000000000000000000000",amount:"100000000000000000000000",assetBalance:"10000000000000000000000000",nativeBalance:"10000000000000000000000000",
              reserve:"1820000000000000000000",storageDeposit:token ? "1250000000000000000000":"0",fee:"10000000000000000000000",gasPriceCeiling:"200000000",
              gas:token ? 50_000_000_000_000:0,storageGas:token ? 30_000_000_000_000:0,nonce:123456789000001,blockHash:SuiSendCrypto.base58(Data(repeating:3,count:32)),blockHeight:100,validityPeriod:86400)
    }
    static func changing(_ p:NearSendPlan,_ edits:[String:Any]) throws -> NearSendPlan {
        var j=try JSONSerialization.jsonObject(with:JSONEncoder().encode(p)) as! [String:Any];for (k,v) in edits { j[k]=v };return try JSONDecoder().decode(NearSendPlan.self,from:JSONSerialization.data(withJSONObject:j))
    }
    func testOfficialSDKNativeAndTokenRegistrationVectors() throws {
        let vectors=try JSONDecoder().decode([NearJSON].self,from:Self.fixture("vectors"))
        for v in vectors {
            let p=try Self.plan(token:v["token"] == .bool(true)),signed=try NearSendCrypto.sign(p,privateKey:Self.seed)
            XCTAssertEqual(try NearSendCrypto.raw(p).base64EncodedString(),v["raw"].string)
            // CryptoKit may randomize Ed25519's nonce; both signatures must verify over the exact SDK hash.
            let sdkSignature=Data(base64Encoded:v["signature"].string!)!
            let sdk=NearSignedSend(bytes:Data(base64Encoded:v["signed"].string!)!,publicKey:p.publicKey,signature:sdkSignature,hash:v["hash"].string!)
            XCTAssertNoThrow(try NearSendCrypto.verify(sdk,plan:p));XCTAssertEqual(signed.hash,v["hash"].string)
            try JSONEncoder().encode(signed).write(to:URL(fileURLWithPath:"/tmp/oath-near-sdk-verify-\(p.reference == "native" ? "native":"token").json"))
        }
    }
    func testExactU128MaxAndOverflowAndSignatureTampering() throws {
        let max="340282366920938463463374607431768211455"
        XCTAssertEqual(try NearSendAmount.subtract(max,"1"),"340282366920938463463374607431768211454")
        XCTAssertThrowsError(try NearSendAmount.add(max,"1"));XCTAssertThrowsError(try NearSendAmount.multiply(max,2))
        XCTAssertThrowsError(try NearSendAmount.checked("01"));XCTAssertThrowsError(try NearSendAmount.subtract("1","2"))
        let p=try Self.plan(),s=try NearSendCrypto.sign(p,privateKey:Self.seed)
        for edits:[String:Any] in [["recipient":"attacker.testnet"],["amount":"1"],["nonce":123456789000002],["publicKey":Data(repeating:9,count:32).base64EncodedString()]] {
            XCTAssertThrowsError(try NearSendCrypto.verify(s,plan:Self.changing(p,edits)))
        }
        XCTAssertThrowsError(try NearSendCrypto.sign(p,privateKey:Data(repeating:1,count:32)))
        XCTAssertThrowsError(try NearSendCrypto.sign(p,privateKey:Self.seed,now:p.createdAt.addingTimeInterval(91)))
        XCTAssertNoThrow(try NearSendCrypto.verify(s,plan:Self.changing(p,["createdAt":0])))
    }
    func testLiveFinalPreflightNativeAndToken() async throws {
        guard let path=ProcessInfo.processInfo.environment["OATH_NEAR_FINAL_TESTNET_FIXTURE"] else { throw XCTSkip("Opt-in final NEAR testnet integration check") }
        let f=try JSONDecoder().decode(NearJSON.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        let source=f["recipients"].array![0],seed=Data(base64Encoded:source["seed"].string!)!,sender=source["address"].string!,to=f["sender"].string!
        let client=try NearSendClient(network:.testnet,transport:NearTestnetPacedTransport())
        // The recipient from the earlier suite has only 0.1 NEAR. Fund enough test
        // NEAR for the conservative prepaid FT gas budget before testing reverse sends.
        let sponsor=Data(base64Encoded:f["seed"].string!)!
        let funding=try await client.quote(sender:to,recipient:sender,reference:"native",publicKey:NearSendCrypto.publicKey(privateKey:sponsor),decimals:24,amount:"250000000000000000000000")
        let funded=try await client.submit(NearSendCrypto.sign(funding,privateKey:sponsor),plan:funding)
        XCTAssertEqual(funded.outcome,.confirmed)
        var proof=[[String:String]]()
        for reference in ["native",f["token"].string!] {
            func balance() async throws -> String {
                let h=try await client.finalBlock(),hash=try NearIdentity.hash(h["hash"])
                if reference=="native" { return try NearIdentity.amount(await client.account(to,block:hash)["amount"]) }
                return try NearIdentity.amount(await client.call(reference,"ft_balance_of",["account_id":.string(to)],block:hash))
            }
            let before=try await balance()
            let plan=try await client.quote(sender:sender,recipient:to,reference:reference,publicKey:NearSendCrypto.publicKey(privateKey:seed),decimals:24,amount:"10000000000000000000000")
            try await client.preflight(plan)
            let signed=try NearSendCrypto.sign(plan,privateKey:seed)
            var receipt=try await client.submit(signed,plan:plan)
            for _ in 0..<20 where receipt.outcome == .unknown || receipt.outcome == .accepted { try await Task.sleep(for:.seconds(2));receipt=try await client.status(signed,plan:plan) }
            XCTAssertEqual(receipt.outcome,.confirmed)
            XCTAssertFalse(XrplSendAmount.less(plan.fee,try XCTUnwrap(receipt.fee)))
            let after=try await balance();XCTAssertEqual(try NearSendAmount.subtract(after,before),plan.amount)
            proof.append(["hash":signed.hash,"kind":reference,"outcome":receipt.outcome.rawValue,"fee":receipt.fee!])
        }
        try JSONSerialization.data(withJSONObject:proof,options:.prettyPrinted).write(to:URL(fileURLWithPath:"/tmp/oath-near-final-testnet-results.json"),options:.atomic)
    }
    func testLiveTestnetNativeTokensMaxAndFailure() async throws {
        guard let path=ProcessInfo.processInfo.environment["OATH_NEAR_TESTNET_FIXTURE"] else { throw XCTSkip("Opt-in live NEAR testnet transfers") }
        let f=try JSONDecoder().decode(NearJSON.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        let seed=Data(base64Encoded:f["seed"].string!)!,pub=try NearSendCrypto.publicKey(privateKey:seed),sender=f["sender"].string!,recipients=f["recipients"].array!
        let client=try NearSendClient(network:.testnet,transport:NearTestnetPacedTransport())
        var results=[[String:String]]()
        func balance(_ owner:String,_ token:String) async throws -> String {
            let block=try await client.finalBlock(),hash=try NearIdentity.hash(block["hash"])
            if token=="native" { return try NearIdentity.amount(await client.account(owner,block:hash)["amount"]) }
            return try NearIdentity.amount(await client.call(token,"ft_balance_of",["account_id":.string(owner)],block:hash))
        }
        func execute(_ p:NearSendPlan,_ key:Data,expect:NearSendReceipt.Outcome = .confirmed) async throws -> NearSendReceipt {
            let signed=try NearSendCrypto.sign(p,privateKey:key)
            var result=try await client.submit(signed,plan:p)
            for _ in 0..<20 where result.outcome == .unknown || result.outcome == .accepted { try await Task.sleep(for:.seconds(2));result=try await client.status(signed,plan:p) }
            XCTAssertEqual(result.outcome,expect);XCTAssertNotNil(result.fee)
            if let fee=result.fee { XCTAssertFalse(XrplSendAmount.less(p.fee,fee)) }
            let retry=try await client.submit(signed,plan:p);XCTAssertEqual(retry.outcome,expect)
            results.append(["kind":p.reference,"hash":signed.hash,"outcome":result.outcome.rawValue,"fee":result.fee ?? "unknown","amount":p.amount,"storage":p.storageDeposit])
            try JSONSerialization.data(withJSONObject:results,options:.prettyPrinted).write(to:URL(fileURLWithPath:"/tmp/oath-near-testnet-results.json"),options:.atomic)
            print("NEAR_TESTNET",p.reference,result.outcome.rawValue,signed.hash)
            return result
        }
        // Activate three fresh implicit accounts. The production signer, Borsh encoder, fee
        // estimator, RPC client, and finality verifier are used for every transfer below.
        for recipient in recipients {
            let to=recipient["address"].string!,before=try await balance(sender,"native")
            let p=try await client.quote(sender:sender,recipient:to,reference:"native",publicKey:pub,decimals:24,amount:"100000000000000000000000")
            try await client.preflight(p);let receipt=try await execute(p,seed)
            let received=try await balance(to,"native"),after=try await balance(sender,"native")
            XCTAssertEqual(received,p.amount);XCTAssertEqual(try NearSendAmount.subtract(before,after),try NearSendAmount.add(p.amount,receipt.fee!))
        }
        let to=recipients[0]["address"].string!,token=f["token"].string!
        // First FT send must register the recipient atomically; the second reuses that registration.
        for index in 0..<2 {
            let before=try await balance(to,token),nativeBefore=try await balance(sender,"native")
            let p=try await client.quote(sender:sender,recipient:to,reference:token,publicKey:pub,decimals:24,amount:"10000000000000000000000")
            XCTAssertEqual(p.storageDeposit=="0",index==1)
            let receipt=try await execute(p,seed),after=try await balance(to,token),nativeAfter=try await balance(sender,"native")
            XCTAssertEqual(try NearSendAmount.subtract(after,before),p.amount)
            XCTAssertEqual(try NearSendAmount.subtract(nativeBefore,nativeAfter),try NearSendAmount.add(try NearSendAmount.add(p.storageDeposit,"1"),receipt.fee!))
        }
        // Reproduce a stale registration quote: the recipient is no longer registered when
        // execution happens. The contract rejects it; the wallet must not mark it successful.
        let failing=try await client.quote(sender:sender,recipient:recipients[1]["address"].string!,reference:token,publicKey:pub,decimals:24,amount:"10000000000000000000000")
        let stale=try Self.changing(failing,["storageDeposit":"0","storageGas":0])
        _ = try await execute(stale,seed,expect:.failed)
        let unchanged=try await balance(recipients[1]["address"].string!,token);XCTAssertEqual(unchanged,"0")
        // Send all remaining FT, preserving NEAR for gas; then send Max from an implicit account.
        let tokenMax=try await client.quote(sender:sender,recipient:to,reference:token,publicKey:pub,decimals:24,amount:"1",maximum:true)
        let tokenBefore=try await balance(to,token);_ = try await execute(tokenMax,seed)
        let tokenAfter=try await balance(to,token),senderTokenAfter=try await balance(sender,token)
        XCTAssertEqual(senderTokenAfter,"0");XCTAssertEqual(try NearSendAmount.subtract(tokenAfter,tokenBefore),tokenMax.amount)
        let maxSeed=Data(base64Encoded:recipients[2]["seed"].string!)!,maxSender=recipients[2]["address"].string!
        let maxPlan=try await client.quote(sender:maxSender,recipient:sender,reference:"native",publicKey:NearSendCrypto.publicKey(privateKey:maxSeed),decimals:24,amount:"1",maximum:true)
        let maxBefore=try await balance(maxSender,"native"),maxReceipt=try await execute(maxPlan,maxSeed),maxAfter=try await balance(maxSender,"native")
        XCTAssertEqual(try NearSendAmount.subtract(maxBefore,maxAfter),try NearSendAmount.add(maxPlan.amount,maxReceipt.fee!))
        XCTAssertFalse(XrplSendAmount.less(maxAfter,maxPlan.reserve))
        let report=try JSONSerialization.data(withJSONObject:results,options:.prettyPrinted)
        try report.write(to:URL(fileURLWithPath:"/tmp/oath-near-testnet-results.json"),options:.atomic)
    }
}

/// Public testnet deliberately limits bursts. This test-only adapter paces the suite and
/// retries HTTP 429 using the identical request; it never changes a signed transaction.
private actor NearTestnetPacedTransport:AnkrTransport {
    let base=AnkrHTTPTransport()
    var next=Date.distantPast
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        for attempt in 0..<5 {
            let slot=max(next,Date.now);next=slot.addingTimeInterval(0.6)
            let delay=slot.timeIntervalSinceNow
            if delay>0 { try await Task.sleep(for:.seconds(delay)) }
            let result=try await base.send(request)
            if result.1 != 429 || attempt==4 { return result }
            try await Task.sleep(for:.seconds(Double(2 << attempt)))
        }
        throw NearSendError.transport
    }
}

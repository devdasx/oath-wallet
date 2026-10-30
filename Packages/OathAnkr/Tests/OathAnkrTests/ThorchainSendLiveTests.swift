import XCTest
@testable import OathAnkr

@MainActor final class ThorchainSendLiveTests:XCTestCase {
    func testMainnetQuoteReadOnly() async throws {
        guard ProcessInfo.processInfo.environment["OATH_THORCHAIN_SEND_MAINNET_READ"]=="1" else {throw XCTSkip("Opt-in public mainnet reads only")}
        let sender="thor172egzpvhpe4pgd69ql4fjr6sjrlrftkgat79m2",recipient="thor1m4mkgn97q9zj07qzan66n9hz7ddzsnks6efhac"
        let response=try await ThorchainClient().read(ThorchainClient.node,path:"cosmos/auth/v1beta1/accounts/"+sender)
        let pub=try XCTUnwrap(response["account"]["pub_key"]["key"].string.flatMap{Data(base64Encoded:$0)})
        let c=try ThorchainSendClient()
        let plan=try await c.quote(sender:sender,recipient:recipient,reference:"native",publicKey:pub,decimals:8,amount:"1")
        XCTAssertEqual(plan.network,.mainnet);XCTAssertEqual(plan.amount,"1");XCTAssertGreaterThan(plan.fee,0)
        try await c.preflight(plan)
        print("Read-only mainnet quote and preflight passed; fee \(plan.fee) RUNE atomic units. No signing or broadcast.")
    }
    func testLocalExecutionFailureAndUnusedTransactionExpiry() async throws {
        guard let path=ProcessInfo.processInfo.environment["OATH_THORCHAIN_SEND_FIXTURE"] else {throw XCTSkip("Opt-in isolated THORNode")}
        struct Fixture:Decodable {let privateKey:String,sender:String,publicKey:String,recipient:String}
        let f=try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        let c=try ThorchainSendClient(network:.localTestnet,localAPI:URL(string:"http://127.0.0.1:28317")!,localRPC:URL(string:"http://127.0.0.1:28657")!)
        let q=try await c.quote(sender:f.sender,recipient:f.recipient,reference:"native",publicKey:TronIdentity.hex(f.publicKey),decimals:8,amount:"1")
        let tooMuch=try ThorchainSendAmount.add(q.nativeBalance,"1"),invented=try ThorchainSendAmount.add(tooMuch,String(q.fee))
        // Deliberately bypass the successful quote's balance to exercise a real
        // DeliverTx rejection. Production quote never authorizes this amount.
        let invalid=ThorchainSendPlan(network:q.network,sender:q.sender,recipient:q.recipient,reference:"native",publicKey:q.publicKey,decimals:8,requestedAmount:tooMuch,amount:tooMuch,assetBalance:invented,nativeBalance:invented,accountNumber:q.accountNumber,sequence:q.sequence,fee:q.fee,height:q.height,timeoutHeight:q.timeoutHeight)
        let before=try await c.balance(owner:f.recipient,reference:"native")
        let signed=try ThorchainSendCrypto.sign(invalid,privateKey:TronIdentity.hex(f.privateKey))
        _ = try await c.submit(signed,plan:invalid,reconcileFirst:false)
        var receipt=ThorchainSendReceipt(hash:signed.hash,outcome:.unknown)
        for _ in 0..<30 {try await Task.sleep(for:.seconds(1));receipt=try await c.status(signed,plan:invalid);if receipt.outcome == .failed {break}}
        XCTAssertEqual(receipt.outcome,.failed);XCTAssertEqual(receipt.fee,q.fee)
        let after=try await c.balance(owner:f.recipient,reference:"native");XCTAssertEqual(after,before)
        let expiry=try await c.quote(sender:f.sender,recipient:f.recipient,reference:"native",publicKey:q.publicKey,decimals:8,amount:"1")
        let unused=try ThorchainSendCrypto.sign(expiry,privateKey:TronIdentity.hex(f.privateKey))
        for _ in 0..<60 {try await Task.sleep(for:.seconds(1));receipt=try await c.status(unused,plan:expiry);if receipt.outcome == .expired {break}}
        XCTAssertEqual(receipt.outcome,.expired);XCTAssertNil(receipt.fee)
        print("Real THORNode execution failure charged only its fee; unused signed transaction expired without a transfer.")
    }
    func testLocalTHORNodeNativeAndTokenTransfers() async throws {
        guard let path=ProcessInfo.processInfo.environment["OATH_THORCHAIN_SEND_FIXTURE"] else {throw XCTSkip("Opt-in isolated THORNode test network")}
        struct Fixture:Decodable {let privateKey:String,sender:String,publicKey:String,recipient:String}
        let f=try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        let client=try ThorchainSendClient(network:.localTestnet,localAPI:URL(string:"http://127.0.0.1:28317")!,localRPC:URL(string:"http://127.0.0.1:28657")!)
        var evidence=[[String:String]]()
        for reference in ["native","tcy","x/ruji","x/oath-test"] {
            let before=try await client.balance(owner:f.recipient,reference:reference)
            let senderBefore=try await client.balance(owner:f.sender,reference:"native")
            let p=try await client.quote(sender:f.sender,recipient:f.recipient,reference:reference,publicKey:TronIdentity.hex(f.publicKey),decimals:reference=="x/oath-test" ? 6:8,amount:"123456")
            try await client.preflight(p)
            let signed=try ThorchainSendCrypto.sign(p,privateKey:TronIdentity.hex(f.privateKey))
            let start=Date();let accepted=try await client.submit(signed,plan:p,reconcileFirst:false)
            XCTAssertEqual(accepted.outcome,.accepted)
            let latency=Date().timeIntervalSince(start)
            var receipt=accepted
            for _ in 0..<60 {
                try await Task.sleep(for:.seconds(1))
                receipt=try await client.status(signed,plan:p)
                if receipt.outcome != .unknown && receipt.outcome != .accepted {break}
            }
            XCTAssertEqual(receipt.outcome,.confirmed)
            XCTAssertEqual(receipt.fee,p.fee)
            let after=try await client.balance(owner:f.recipient,reference:reference)
            XCTAssertEqual(try ThorchainSendAmount.subtract(after,before),p.amount)
            let senderAfter=try await client.balance(owner:f.sender,reference:"native")
            XCTAssertEqual(try ThorchainSendAmount.subtract(senderBefore,senderAfter),try ThorchainSendAmount.add(String(p.fee),reference=="native" ? p.amount:"0"))
            let replay=try await client.submit(signed,plan:p);XCTAssertEqual(replay.outcome,.confirmed)
            evidence.append(["reference":reference,"hash":signed.hash,"fee":String(p.fee),"height":String(receipt.height ?? 0),"recipientDelta":try ThorchainSendAmount.subtract(after,before),"ackSeconds":String(latency)])
        }
        // Two independent signed intents use the same sequence. Only the one
        // committed to the node may win; recovery must prove the replacement.
        let original=try await client.quote(sender:f.sender,recipient:f.recipient,reference:"native",publicKey:TronIdentity.hex(f.publicKey),decimals:8,amount:"100")
        let replacement=try await client.quote(sender:f.sender,recipient:f.recipient,reference:"native",publicKey:TronIdentity.hex(f.publicKey),decimals:8,amount:"101")
        XCTAssertEqual(original.sequence,replacement.sequence)
        let old=try ThorchainSendCrypto.sign(original,privateKey:TronIdentity.hex(f.privateKey)),new=try ThorchainSendCrypto.sign(replacement,privateKey:TronIdentity.hex(f.privateKey))
        _ = try await client.submit(new,plan:replacement,reconcileFirst:false)
        var replaced=ThorchainSendReceipt(hash:old.hash,outcome:.unknown)
        for _ in 0..<30 {
            try await Task.sleep(for:.seconds(1));replaced=try await client.status(old,plan:original)
            if replaced.outcome == .replaced {break}
        }
        XCTAssertEqual(replaced.outcome,.replaced);XCTAssertEqual(replaced.replacementHash,new.hash)
        evidence.append(["case":"replacement","originalHash":old.hash,"replacementHash":new.hash,"outcome":replaced.outcome.rawValue])
        try JSONEncoder().encode(evidence).write(to:URL(fileURLWithPath:"/tmp/oath-thor-send-live-evidence.json"))
    }
}

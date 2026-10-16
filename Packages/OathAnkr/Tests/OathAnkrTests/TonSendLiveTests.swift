import XCTest
@testable import OathAnkr

@MainActor final class TonSendLiveTests:XCTestCase {
    func testMaxMemoAndFirstWalletDeployment() async throws {
        guard ProcessInfo.processInfo.environment["OATH_TON_LIVE"]=="1",let file=ProcessInfo.processInfo.environment["OATH_TON_FIXTURE"] else { throw XCTSkip("Explicit isolated testnet fixture required") }
        struct Fixture:Decodable { let seed:String,recipientSeed:String,sender:String,recipient:String,jetton:String }
        let f=try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:file)))
        let client=try TonSendClient(network:.testnet,transport:TonLiveTransport())
        // First fund the isolated recipient for its Jetton-wallet execution.
        // Then send its full Jetton balance and its spendable native balance back.
        for (name,seed,from,to,reference,amount,max) in [
            ("memo-funding",f.seed,f.sender,f.recipient,"native","300000000",false),
            ("jetton-max",f.recipientSeed,f.recipient,f.sender,f.jetton,"1",true),
            ("native-max",f.recipientSeed,f.recipient,f.sender,"native","1",true)
        ] {
            let key=try TronIdentity.hex(seed)
            let p=try await client.quote(sender:from,recipient:to,reference:reference,publicKey:TonSendCrypto.publicKey(privateKey:key),decimals:9,amount:amount,maximum:max,memo:"Oath testnet validation")
            if max { XCTAssertEqual(p.remaining,0) }
            XCTAssertGreaterThan(p.fee,0);try await client.preflight(p)
            let s=try TonSendCrypto.sign(p,privateKey:key);try TonSendCrypto.verify(s,plan:p)
            struct Journal:Codable { let plan:TonSendPlan,signed:TonSignedSend }
            let journal=URL(fileURLWithPath:"/tmp/oath-gram-live/"+name+"-journal.json")
            try JSONEncoder().encode(Journal(plan:p,signed:s)).write(to:journal,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:journal.path)
            let submitted=try await client.submit(s,plan:p)
            XCTAssertTrue([.accepted,.confirmed].contains(submitted.outcome))
            var confirmed=false
            for _ in 0..<35 {
                try await Task.sleep(for:.seconds(4))
                let r=try await client.status(s,plan:p)
                if r.outcome == .confirmed {
                    XCTAssertNotNil(r.transactionHash);XCTAssertLessThanOrEqual(r.fee!,p.feeReserve)
                    let evidence=["messageHash":s.hash,"transactionHash":r.transactionHash!,"amount":String(p.amount),"fee":String(r.fee!),"deployedWallet":String(p.deploy)]
                    try JSONEncoder().encode(evidence).write(to:URL(fileURLWithPath:"/tmp/oath-gram-live/"+name+"-evidence.json"))
                    confirmed=true;break
                }
                XCTAssertNotEqual(r.outcome,.failed)
            }
            guard confirmed else { XCTFail("Testnet receipt missing for \(name)");return }
        }
    }
    func testNativeTestnetFeeSignBroadcastAndRecipientReceipt() async throws {
        guard ProcessInfo.processInfo.environment["OATH_TON_LIVE"]=="1",let file=ProcessInfo.processInfo.environment["OATH_TON_FIXTURE"] else { throw XCTSkip("Explicit isolated testnet fixture required") }
        struct Fixture:Decodable { let seed:String,sender:String,recipient:String }
        let f=try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:file))),key=try TronIdentity.hex(f.seed)
        let client=try TonSendClient(network:.testnet,transport:TonLiveTransport())
        let p=try await client.quote(sender:f.sender,recipient:f.recipient,reference:"native",publicKey:TonSendCrypto.publicKey(privateKey:key),decimals:9,amount:"10000000")
        XCTAssertGreaterThan(p.fee,0);try await client.preflight(p)
        let s=try TonSendCrypto.sign(p,privateKey:key);try TonSendCrypto.verify(s,plan:p)
        // Save exact bytes before broadcasting, so interrupted tests can recover.
        let journal=URL(fileURLWithPath:"/tmp/oath-gram-live/native-journal.json")
        struct Journal:Codable { let plan:TonSendPlan,signed:TonSignedSend }
        try JSONEncoder().encode(Journal(plan:p,signed:s)).write(to:journal,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:journal.path)
        let submission=try await client.submit(s,plan:p)
        XCTAssertTrue([.accepted,.confirmed].contains(submission.outcome))
        for _ in 0..<35 {
            try await Task.sleep(for:.seconds(4))
            let receipt=try await client.status(s,plan:p)
            if receipt.outcome == .confirmed {
                XCTAssertNotNil(receipt.transactionHash);XCTAssertLessThanOrEqual(receipt.fee!,p.feeReserve)
                let evidence:[String:TonJSON] = ["messageHash":.string(s.hash),"transactionHash":.string(receipt.transactionHash!),"estimatedFee":.string(String(p.fee)),"actualFee":.string(String(receipt.fee!)),"amount":.string(String(p.amount)),"lt":.string(String(receipt.lt!))]
                try JSONEncoder().encode(evidence).write(to:URL(fileURLWithPath:"/tmp/oath-gram-live/native-evidence.json"))
                return
            }
            XCTAssertNotEqual(receipt.outcome,.failed)
        }
        XCTFail("Testnet recipient receipt not observed within bounded wait")
    }
    func testJettonTestnetFeeSignBroadcastAndRecipientReceipt() async throws {
        guard ProcessInfo.processInfo.environment["OATH_TON_LIVE"]=="1",let file=ProcessInfo.processInfo.environment["OATH_TON_FIXTURE"] else { throw XCTSkip("Explicit isolated testnet fixture required") }
        struct Fixture:Decodable { let seed:String,sender:String,recipient:String,jetton:String }
        let f=try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:file))),key=try TronIdentity.hex(f.seed)
        let client=try TonSendClient(network:.testnet,transport:TonLiveTransport())
        let p=try await client.quote(sender:f.sender,recipient:f.recipient,reference:f.jetton,publicKey:TonSendCrypto.publicKey(privateKey:key),decimals:9,amount:"10000000")
        XCTAssertGreaterThan(p.fee,0);try await client.preflight(p)
        let s=try TonSendCrypto.sign(p,privateKey:key);try TonSendCrypto.verify(s,plan:p)
        // Save exact bytes before broadcasting, so interrupted tests can recover.
        let journal=URL(fileURLWithPath:"/tmp/oath-gram-live/jetton-journal.json")
        struct Journal:Codable { let plan:TonSendPlan,signed:TonSignedSend }
        try JSONEncoder().encode(Journal(plan:p,signed:s)).write(to:journal,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:journal.path)
        let submission=try await client.submit(s,plan:p)
        XCTAssertTrue([.accepted,.confirmed].contains(submission.outcome))
        for _ in 0..<35 {
            try await Task.sleep(for:.seconds(4))
            let receipt=try await client.status(s,plan:p)
            if receipt.outcome == .confirmed {
                XCTAssertNotNil(receipt.transactionHash);XCTAssertLessThanOrEqual(receipt.fee!,p.feeReserve)
                let evidence:[String:TonJSON] = ["messageHash":.string(s.hash),"transactionHash":.string(receipt.transactionHash!),"estimatedFee":.string(String(p.fee)),"actualFee":.string(String(receipt.fee!)),"amount":.string(String(p.amount)),"lt":.string(String(receipt.lt!))]
                try JSONEncoder().encode(evidence).write(to:URL(fileURLWithPath:"/tmp/oath-gram-live/jetton-evidence.json"))
                return
            }
            XCTAssertNotEqual(receipt.outcome,.failed)
        }
        XCTFail("Testnet recipient receipt not observed within bounded wait")
    }
}

struct TonLiveTransport:AnkrTransport {
    let base=AnkrHTTPTransport()
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        let result=try await base.send(request)
        let method=request.httpBody.flatMap { try? JSONDecoder().decode(TonJSON.self,from:$0) }?["method"].string ?? "index"
        if request.url?.path=="/v2/traces/emulate",result.1==200 {
            try result.0.write(to:URL(fileURLWithPath:"/tmp/oath-gram-live/last-emulation.json"),options:.atomic)
        }
        let response=try? JSONDecoder().decode(TonJSON.self,from:result.0)
        print("TON test transport",method,result.1,response?["code"].text ?? "",response?["error"]["code"].text ?? "")
        return result
    }
}

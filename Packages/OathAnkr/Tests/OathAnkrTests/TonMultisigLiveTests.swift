import XCTest
@testable import OathAnkr

@MainActor final class TonMultisigLiveTests: XCTestCase {
    struct Fixture:Decodable {
        struct Policy:Decodable { let k:Int,n:Int,address:String }
        let seeds:[String],recipient:String,jetton:String,policies:[Policy]
    }
    func testNativeAndJettonThresholdsOnPublicTestnet() async throws {
        guard let folder=ProcessInfo.processInfo.environment["OATH_GRAM_MULTISIG_LIVE"] else { throw XCTSkip("Explicit disposable public-testnet fixture required") }
        let root=URL(fileURLWithPath:folder)
        let f=try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:root.appendingPathComponent("fixture.json")))
        let client=try TonSendClient(network:.testnet)
        var evidence=[[String:String]]()
        for policy in f.policies {
            let keys=try f.seeds.prefix(policy.n).map(TronIdentity.hex)
            let p=try TonMultisigPolicy(required:policy.k,publicKeys:keys.map(TonSendCrypto.publicKey))
            XCTAssertEqual(try p.address(network:.testnet),policy.address)
            for reference in ["native",f.jetton] {
                let name="\(policy.k)-\(policy.n)-"+(reference=="native" ? "native":"jetton")
                let journal=root.appendingPathComponent(name+"-journal.json")
                struct Journal:Codable { let plan:TonSendPlan,signed:TonSignedSend }
                let plan:TonSendPlan,signed:TonSignedSend
                if FileManager.default.fileExists(atPath:journal.path) {
                    let stored=try JSONDecoder().decode(Journal.self,from:Data(contentsOf:journal));plan=stored.plan;signed=stored.signed
                } else {
                    plan=try await client.quote(sender:policy.address,recipient:f.recipient,reference:reference,publicKey:p.publicKeys[0],decimals:9,amount:reference=="native" ? "1000000":"100000000",memo:"Oath GRAM multisig testnet",multisig:p)
                    try await client.preflight(plan)
                    // Vary subset as well as threshold; every key is independently checked.
                    signed=try TonMultisigCrypto.sign(plan,privateKeys:Array(keys.suffix(policy.k)))
                    try TonSendCrypto.verify(signed,plan:plan)
                    try JSONEncoder().encode(Journal(plan:plan,signed:signed)).write(to:journal,options:.atomic)
                    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:journal.path)
                }
                _ = try await client.submit(signed,plan:plan)
                var receipt:TonSendReceipt?
                for _ in 0..<35 {
                    try await Task.sleep(for:.seconds(4.5))
                    let next=try await client.status(signed,plan:plan)
                    if next.outcome == .confirmed { receipt=next;break }
                    XCTAssertNotEqual(next.outcome,.failed)
                    if next.outcome == .failed { throw TonSendError.execution }
                }
                guard let receipt else { XCTFail("Public testnet receipt not observed: \(name)");return }
                XCTAssertLessThanOrEqual(try XCTUnwrap(receipt.fee),plan.feeReserve)
                // A fresh quote reads the live owner and Jetton wallets, validates
                // their bindings, and observes the post-transfer asset balance.
                let after=try await client.quote(sender:policy.address,recipient:f.recipient,reference:reference,publicKey:p.publicKeys[0],decimals:9,amount:"1",multisig:p)
                if reference=="native" { XCTAssertLessThanOrEqual(after.assetBalance,plan.assetBalance-plan.amount.uint64!) }
                else { XCTAssertEqual(after.assetBalance,plan.assetBalance-plan.amount.uint64!) }
                let stream:TonStream = reference=="native" ? .native:.jettons
                let path=stream == .native ? "blockchain/accounts/\(policy.address)/transactions?limit=100":"accounts/\(policy.address)/jettons/history?limit=100"
                var page:TonHistoryPage?
                for _ in 0..<8 {
                    try await Task.sleep(for:.seconds(4.5))
                    let (data,response)=try await URLSession.shared.data(from:URL(string:"https://testnet.tonapi.io/v2/"+path)!)
                    guard (response as? HTTPURLResponse)?.statusCode==200 else { continue }
                    let decoded=try TonDecoding.history(JSONDecoder().decode(TonJSON.self,from:data),owner:policy.address,stream:stream,before:nil,limit:100)
                    if decoded.transactions.contains(where: { tx in
                        tx.hash == receipt.transactionHash && !tx.failed && tx.events.contains {
                            $0.from == policy.address && $0.to == f.recipient && $0.token.reference == reference && $0.amount == String(plan.amount)
                        }
                    }) { page=decoded;break }
                }
                XCTAssertNotNil(page,"Production history must contain the exact confirmed hash, recipient, token and amount")
                evidence.append(["case":name,"messageHash":signed.hash,"transactionHash":receipt.transactionHash!,"amount":String(plan.amount),"before":String(plan.assetBalance),"after":String(after.assetBalance),"fee":String(receipt.fee!),"sender":policy.address])
                try JSONEncoder().encode(evidence).write(to:root.appendingPathComponent("evidence.json"),options:.atomic)
                print("Confirmed GRAM testnet case",name)
            }
        }
    }

    func testRecordedTransfersHaveExactProductionHistoryEntries() async throws {
        guard let folder=ProcessInfo.processInfo.environment["OATH_GRAM_MULTISIG_LIVE"] else { throw XCTSkip("Explicit disposable public-testnet fixture required") }
        let root=URL(fileURLWithPath:folder)
        let f=try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:root.appendingPathComponent("fixture.json")))
        let evidence=try JSONDecoder().decode([[String:String]].self,from:Data(contentsOf:root.appendingPathComponent("evidence.json")))
        XCTAssertEqual(evidence.count,f.policies.count*2)
        for e in evidence {
            let sender=try XCTUnwrap(e["sender"]),name=try XCTUnwrap(e["case"])
            let native=name.hasSuffix("native"),stream:TonStream=native ? .native:.jettons
            let path=native ? "blockchain/accounts/\(sender)/transactions?limit=100":"accounts/\(sender)/jettons/history?limit=100"
            try await Task.sleep(for:.seconds(4.5))
            let (data,response)=try await URLSession.shared.data(from:URL(string:"https://testnet.tonapi.io/v2/"+path)!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
            let page=try TonDecoding.history(JSONDecoder().decode(TonJSON.self,from:data),owner:sender,stream:stream,before:nil,limit:100)
            XCTAssertTrue(page.transactions.contains { tx in
                tx.hash == e["transactionHash"] && !tx.failed && tx.events.contains {
                    $0.from == sender && $0.to == f.recipient && $0.token.reference == (native ? "native":f.jetton) && $0.amount == e["amount"]
                }
            },"Exact production history entry: \(name)")
        }
    }
}

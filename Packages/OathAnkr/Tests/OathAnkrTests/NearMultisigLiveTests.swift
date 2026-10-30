import XCTest
import Foundation
import CryptoKit
@testable import OathAnkr

@MainActor final class NearMultisigLiveTests: XCTestCase {
    struct Fixture: Decodable {
        struct Wallet: Decodable {
            struct Key: Decodable { let key, publicKey: String }
            let required, count: Int; let address, bootstrap: String; let keys: [Key]
        }
        let recipient, token: String; let wallets: [Wallet]
    }
    func seed(_ text:String) throws -> Data { Data(try SolanaSendCrypto.decode(String(text.dropFirst(8))).prefix(32)) }
    func complete(_ client:NearSendClient,_ signed:NearSignedSend,_ plan:NearSendPlan) async throws -> NearSendReceipt {
        for _ in 0..<150 {
            let r=try await client.submit(signed,plan:plan)
            if r.outcome != .unknown { return r }
            try await Task.sleep(for:.seconds(1))
        }
        throw NearSendError.execution
    }
    func balance(_ client:NearSendClient,_ owner:String,_ reference:String) async throws -> String {
        let h=try await client.finalBlock(),block=try NearIdentity.hash(h["hash"])
        if reference=="native" { return try await NearIdentity.amount(client.account(owner,block:block)["amount"]) }
        return try await NearIdentity.amount(client.call(reference,"ft_balance_of",["account_id":.string(owner)],block:block))
    }
    func testTestnetActivationTransfersAndBalances() async throws {
        guard ProcessInfo.processInfo.environment["OATH_NEAR_MULTISIG_LIVE"]=="1" else { throw XCTSkip("Explicit disposable Testnet opt-in required") }
        let f=try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:"/tmp/oath-near-multisig-testnet.json")))
        let client=try NearSendClient(network:.testnet,transport:NearMultisigLiveTransport())
        for w in f.wallets {
            let bootstrap=try seed(w.bootstrap)
            let policy=try NearMultisigPolicy(bootstrap:Curve25519.Signing.PrivateKey(rawRepresentation:bootstrap).publicKey.rawRepresentation,required:w.required,publicKeys:w.keys.map { try TronIdentity.hex($0.publicKey) })
            XCTAssertEqual(policy.address,w.address)
            for _ in 0..<2 {
                let (state,plan)=try await client.multisigSetup(policy)
                if state.configured { break }
                let p=try XCTUnwrap(plan)
                try await client.preflight(p)
                let signed=try NearSendCrypto.sign(p,privateKeys:[bootstrap])
                let r=try await complete(client,signed,p)
                XCTAssertEqual(r.outcome,.confirmed)
                print("NEAR_MULTISIG_ACTIVATED policy=\(w.required)/\(w.count) stage=\(p.multisig!.stage.rawValue) hash=\(signed.hash)")
            }
            let (state,_)=try await client.multisigSetup(policy);XCTAssertTrue(state.configured)
            var keys=try w.keys.prefix(w.required).map { try seed($0.key) }
            defer { for i in keys.indices { keys[i].resetBytes(in:0..<keys[i].count) } }
            for ref in ["native",f.token] {
                let url=URL(fileURLWithPath:"/tmp/oath-near-public-\(w.required)-\(w.count)-\(ref == "native" ? "near":"token").json")
                if FileManager.default.fileExists(atPath:url.path) {
                    let saved=try JSONDecoder().decode(PublicEvidence.self,from:Data(contentsOf:url))
                    let resumed=try await complete(client,saved.signed,saved.plan)
                    XCTAssertEqual(resumed.outcome,.confirmed)
                    if saved.verified != true, let before=saved.receiverBefore {
                        let after=try await balance(client,f.recipient,ref)
                        XCTAssertEqual(after,try NearSendAmount.add(before,saved.plan.amount))
                    }
                    var verified=saved;verified.verified=true
                    try JSONEncoder().encode(verified).write(to:url,options:.atomic)
                    print("NEAR_MULTISIG_RESUMED policy=\(w.required)/\(w.count) asset=\(ref == "native" ? "NEAR":"NEP141") hash=\(saved.signed.hash) confirmed=true")
                    continue
                }
                let before=try await balance(client,f.recipient,ref)
                let beforeSender=try await balance(client,w.address,ref)
                let beforeNative=try await balance(client,w.address,"native")
                let plan=try await client.quote(sender:w.address,recipient:f.recipient,reference:ref,publicKey:policy.publicKeys[0],decimals:24,amount:"123450000000000000000",multisig:policy)
                try await client.preflight(plan)
                let signed=try NearSendCrypto.sign(plan,privateKeys:keys)
                FileManager.default.createFile(atPath:url.path,contents:try JSONEncoder().encode(PublicEvidence(plan:plan,signed:signed,receiverBefore:before)),attributes:[.posixPermissions:0o600])
                let r=try await complete(client,signed,plan)
                XCTAssertEqual(r.outcome,.confirmed)
                let after=try await balance(client,f.recipient,ref)
                XCTAssertEqual(after,try NearSendAmount.add(before,plan.amount))
                let afterSender=try await balance(client,w.address,ref)
                if ref != "native" { XCTAssertEqual(afterSender,try NearSendAmount.subtract(beforeSender,plan.amount)) }
                else { XCTAssertTrue(XrplSendAmount.less(afterSender,try NearSendAmount.subtract(beforeSender,plan.amount))) }
                let afterNative=try await balance(client,w.address,"native")
                let debit=try NearSendAmount.subtract(beforeNative,afterNative)
                XCTAssertFalse(XrplSendAmount.less(plan.nativeDebit,debit),"Actual debit must stay within the reviewed budget")
                let replay=try await complete(client,signed,plan);XCTAssertEqual(replay.outcome,.confirmed)
                let replayBalance=try await balance(client,f.recipient,ref);XCTAssertEqual(replayBalance,after)
                try JSONEncoder().encode(PublicEvidence(plan:plan,signed:signed,receiverBefore:before,verified:true)).write(to:url,options:.atomic)
                // Public signed transaction fixture, no secret material. Used by SDK differential/rejection checks.
                print("NEAR_MULTISIG_CONFIRMED policy=\(w.required)/\(w.count) asset=\(ref == "native" ? "NEAR":"NEP141") hash=\(signed.hash) balances=true replay=true")
            }
        }
    }
    func testTestnetPortfolioAndIndexedTransactionHistory() async throws {
        guard ProcessInfo.processInfo.environment["OATH_NEAR_MULTISIG_HISTORY"]=="1" else { throw XCTSkip("Explicit disposable Testnet history opt-in required") }
        let f=try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:"/tmp/oath-near-multisig-testnet.json")))
        let client=try NearClient(endpoint:URL(string:"https://test.rpc.fastnear.com")!,network:.testnet)
        let sender=try NearSendClient(network:.testnet)
        for w in f.wallets {
            let inventory=try await client.inventory(owner:w.address)
            XCTAssertNotNil(inventory.holdings.first { $0.reference==f.token })
            for ref in ["native",f.token] {
                let value=try await balance(sender,w.address,ref)
                XCTAssertEqual(inventory.holdings.first { $0.reference==ref }?.amount,value)
                let path="/tmp/oath-near-public-\(w.required)-\(w.count)-\(ref == "native" ? "near":"token").json"
                let evidence=try JSONDecoder().decode(PublicEvidence.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
                var page=try await client.history(owner:w.address,stream:"transactions",limit:100)
                for _ in 0..<10 where !page.executions.contains(where:{$0.hash==evidence.signed.hash}) {
                    try await Task.sleep(for:.seconds(2));page=try await client.history(owner:w.address,stream:"transactions",limit:100)
                }
                let row=try XCTUnwrap(page.executions.first { $0.hash==evidence.signed.hash })
                XCTAssertFalse(row.failed);XCTAssertGreaterThan(row.timestamp,0)
                print("NEAR_MULTISIG_HISTORY policy=\(w.required)/\(w.count) asset=\(ref == "native" ? "NEAR":"NEP141") hash=\(row.hash) indexed=true portfolio=true")
            }
        }
    }
    struct PublicEvidence:Codable { let plan:NearSendPlan;let signed:NearSignedSend; var receiverBefore:String? = nil;var verified:Bool? = nil }
}

private actor NearMultisigLiveTransport: AnkrTransport {
    let base=AnkrHTTPTransport();var next=Date.distantPast
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        for attempt in 0..<5 {
            let slot=max(next,Date.now);next=slot.addingTimeInterval(0.15)
            if slot>Date.now { try await Task.sleep(for:.seconds(slot.timeIntervalSinceNow)) }
            let r=try await base.send(request)
            if r.1 != 429 || attempt==4 { return r }
            try await Task.sleep(for:.seconds(Double(1 << attempt)))
        }
        throw NearSendError.transport
    }
}

import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class SolanaMultisigJournalTests: XCTestCase {
    func testEverySignedStageSurvivesRestartAndCannotBeReplaced() async throws {
        for setup in [false,true] {
            let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at:directory) }
            let url=directory.appendingPathComponent("db.sqlite"),db=try await OathDatabase.open(at:url)
            let keys=(1...3).map { Data(repeating:UInt8($0),count:32) },create=Data(repeating:8,count:32)
            let policy=try SolanaMultisigPolicy(createKey:SolanaSendCrypto.address(privateKey:create),required:2,members:keys.map { try SolanaSendCrypto.address(privateKey:$0) })
            let vault=try policy.vault, recipient=try SolanaSendCrypto.address(privateKey:Data(repeating:9,count:32))
            try await db.seed(networks:[.init(id:"solana",name:"Solana",family:"account",symbol:"SOL",decimals:9,derivationPath:"solana-multisig-v1",logo:"solana",sortOrder:0)],assets:[.init(id:"solana:native",networkID:"solana",reference:"native",name:"Solana",symbol:"SOL",decimals:9)])
            try await db.importWalletIfNeeded(.init(id:"w",name:"Test",kind:"solanaMultisig",vaultReference:"fixture",createdAt:1),accounts:[.init(id:"a",walletID:"w",networkID:"solana",address:vault,derivationPath:"solana-multisig-v1")])
            _ = try await db.prepareSolanaReceive(accountID:"a",addresses:[.init(path:"solana-multisig-v1",address:vault)],preferredPath:"solana-multisig-v1")
            let plan=SolanaSendPlan(network:.mainnet,sender:vault,recipient:setup ? vault:recipient,requestedAmount:setup ? 0:1234567,amount:setup ? 0:1234567,assetBalance:100_000_000,nativeBalance:100_000_000,blockhash:policy.createKey,lastValidBlockHeight:500,slot:100,transactionFee:setup ? 10000:15000,multisig:.init(policy:policy,index:setup ? 0:1,payerBalance:100_000_000,storageRent:10000000,setupTreasury:setup ? recipient:nil,feePayer:policy.members.last))
            func draft(_ id:String) async throws {
                try await db.saveDraft(.init(id:id,walletID:"w",accountID:"a",networkID:"solana",assetID:"solana:native",idempotencyKey:id,recipient:plan.recipient,amountAtomic:String(plan.amount),state:"draft",createdAt:Date.now.timeIntervalSince1970,updatedAt:Date.now.timeIntervalSince1970))
            }
            try await draft("one");try await db.queueSolanaSend(sendID:"one",plan:plan)
            let selected=try XCTUnwrap(plan.multisig).signingMembers.map { address in try XCTUnwrap(keys.first { try SolanaSendCrypto.address(privateKey:$0)==address }) }
            let signed=try SolanaMultisigCrypto.sign(plan,privateKeys:setup ? selected+[create]:selected)
            if !setup {
                do { try await db.journalSolanaSignature(sendID:"one",signed:.init(bytes:signed.bytes,publicKey:signed.publicKey,signature:signed.signature,hash:signed.hash));XCTFail("Missing preparation accepted") } catch {}
            }
            try await db.journalSolanaSignature(sendID:"one",signed:signed)
            let reopened=try await OathDatabase.open(at:url),saved=try await reopened.send("one")
            let savedPlan = try await reopened.solanaSendPlan(sendID:"one")
            XCTAssertEqual(savedPlan, plan)
            XCTAssertEqual(savedPlan?.multisig?.payer, policy.members.last)
            let recovered=try JSONDecoder().decode(SolanaSignedSend.self,from:XCTUnwrap(saved?.signedPayload))
            XCTAssertEqual(recovered,signed);XCTAssertEqual(recovered.preparations?.count ?? 0,setup ? 0:1)
            try SolanaSendCrypto.verify(recovered,plan:plan)
            let pending=try await reopened.pendingSolanaMultisigSetup(walletID:"w")
            XCTAssertEqual(pending?.id,setup ? "one":nil)
            let count=try await reopened.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM activity") }
            XCTAssertEqual(count,setup ? 0:1)
            try await draft("two")
            do { try await reopened.queueSolanaSend(sendID:"two",plan:plan);XCTFail("Duplicate pending send") } catch { XCTAssertEqual(error as? SolanaSendError,.busy) }
            let jobs=try await reopened.claimSendStatusChecks(owner:"restart");XCTAssertEqual(jobs.count,1)
        }
    }
}

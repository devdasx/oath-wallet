import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class XrplSendJournalTests: XCTestCase {
    let key = Data(repeating:7,count:32)
    func fixture() async throws -> (OathDatabase,URL,XrplSendPlan) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("XrplSend-"+UUID().uuidString)
        let db = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let owner = try XrplSendCrypto.address(privateKey:key)
        try await db.seed(networks:[.init(id:"xrpl",name:"Xrpl",family:"account",symbol:"XRP",decimals:6,derivationPath:"m/44'/144'/0'/0/0",logo:"xrpl",sortOrder:0)],assets:[.init(id:"xrpl:native",networkID:"xrpl",reference:"native",name:"Xrpl",symbol:"XRP",decimals:6)])
        for i in 1...2 { try await db.importWalletIfNeeded(.init(id:"w\(i)",name:"Test",kind:"hd",vaultReference:"test\(i)",createdAt:1),accounts:[.init(id:"a\(i)",walletID:"w\(i)",networkID:"xrpl",address:owner,derivationPath:"m/44'/144'/0'/0/0")]) }
        let plan = XrplSendPlan(network:.mainnet,sender:owner,recipient:"rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh",reference:"native",
            requestedAmount:"1000000",amount:"1000000",assetDebit:"1000000",assetBalance:"100000000",nativeBalance:100000000,
            reserve:1000000,fee:12,sequence:42,firstLedger:100,lastLedger:120)
        return (db,folder,plan)
    }
    func draft(_ id:String, wallet:Int = 1, plan:XrplSendPlan, db:OathDatabase) async throws {
        try await db.saveDraft(.init(id:id,walletID:"w\(wallet)",accountID:"a\(wallet)",networkID:"xrpl",assetID:"xrpl:native",idempotencyKey:id,
            recipient:plan.recipient,amountAtomic:String(plan.amount),state:"draft",createdAt:Date.now.timeIntervalSince1970,updatedAt:Date.now.timeIntervalSince1970))
    }
    func testCrossWalletReservationAndCancelledAuthenticationReleasesOnlyUnsigned() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await draft("two",wallet:2,plan:plan,db:db)
        try await db.queueXrplSend(sendID:"one",plan:plan)
        do { try await db.queueXrplSend(sendID:"two",plan:plan); XCTFail("Shared address double reservation") } catch { XCTAssertEqual(error as? XrplSendError,.busy) }
        _ = try await db.transitionSend("one",from:"queued",to:"cancelled")
        try await db.queueXrplSend(sendID:"two",plan:plan)
        let signed = try XrplSendCrypto.sign(plan,privateKey:key)
        try await db.journalXrplSignature(sendID:"two",signed:signed)
        do { _ = try await db.transitionSend("two",from:"signed",to:"cancelled"); XCTFail("Signed send released") } catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
    }
    func testExactSignedBytesSurviveReopenAndUnknownBroadcastReservesSender() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await db.queueXrplSend(sendID:"one",plan:plan)
        let signed = try XrplSendCrypto.sign(plan,privateKey:key)
        try await db.journalXrplSignature(sendID:"one",signed:signed)
        _ = try await db.transitionSend("one",from:"signed",to:"broadcast")
        try await db.settleXrplSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.accepted))
        let acknowledged = try await db.pool.read { try Double.fetchOne($0,sql:"SELECT submittedAt FROM xrplSendPlans WHERE sendID='one'") }
        XCTAssertNotNil(acknowledged)
        let checking = try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM sendStatusChecks WHERE sendID='one'") }
        XCTAssertEqual(checking,1,"Acknowledgement must retain durable finality tracking")
        let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let fetched = try await reopened.send("one")
        let stored = try XCTUnwrap(fetched)
        XCTAssertEqual(try JSONDecoder().decode(XrplSignedSend.self,from:XCTUnwrap(stored.signedPayload)),signed)
        try await reopened.settleXrplSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.unknown,fee:nil))
        let pending = try await reopened.send("one"); XCTAssertEqual(pending?.state,"broadcast")
        try await draft("two",wallet:2,plan:plan,db:reopened)
        do { try await reopened.queueXrplSend(sendID:"two",plan:plan); XCTFail("Unknown broadcast released") } catch { XCTAssertEqual(error as? XrplSendError,.busy) }
        try await reopened.settleXrplSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.confirmed,fee:12,ledger:101,code:"tesSUCCESS"))
        let confirmed = try await reopened.send("one"); XCTAssertEqual(confirmed?.state,"confirmed")
        try await reopened.queueXrplSend(sendID:"two",plan:plan)
        let targets = try await reopened.pendingSendBalanceRefreshTargets(); XCTAssertEqual(targets.count,1)
    }
    func testTamperedSignedTransactionAndTestnetPlanRejectedBeforeJournal() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await db.queueXrplSend(sendID:"one",plan:plan)
        let signed = try XrplSendCrypto.sign(plan,privateKey:key)
        var badBytes = signed.bytes; badBytes[20] ^= 1
        do { try await db.journalXrplSignature(sendID:"one",signed:.init(bytes:badBytes,publicKey:signed.publicKey,signature:signed.signature,hash:signed.hash)); XCTFail("Tampered payload") } catch { XCTAssertEqual(error as? XrplSendError,.signing) }
        let testnet = XrplSendPlan(network:.testnet,sender:plan.sender,recipient:plan.recipient,reference:"native",
            requestedAmount:plan.amount,amount:plan.amount,assetDebit:plan.amount,assetBalance:plan.assetBalance,nativeBalance:plan.nativeBalance,
            reserve:plan.reserve,fee:plan.fee,sequence:plan.sequence,firstLedger:plan.firstLedger,lastLedger:plan.lastLedger)
        do { try await db.queueXrplSend(sendID:"one",plan:testnet); XCTFail("Testnet in production ledger") } catch { XCTAssertEqual(error as? XrplSendError,.wrongNetwork) }
    }
    func testFailedExecutionSettlesAsFailureAndNeverSuccess() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await db.queueXrplSend(sendID:"one",plan:plan)
        let signed = try XrplSendCrypto.sign(plan,privateKey:key)
        try await db.journalXrplSignature(sendID:"one",signed:signed)
        try await db.settleXrplSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.failed,fee:12,ledger:101,code:"tecPATH_DRY"))
        let failed = try await db.send("one"); XCTAssertEqual(failed?.state,"failed")
        do { try await db.settleXrplSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.confirmed,fee:12,ledger:101,code:"tesSUCCESS")); XCTFail("Conflicting result") } catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
        let targets = try await db.pendingSendBalanceRefreshTargets(); XCTAssertEqual(targets.count,1)
        do { try await db.settleXrplSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.expired)); XCTFail("Expiry overwrote fee-consuming failure") } catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
    }
    func testProvenExpiryReleasesSenderWithoutClaimingFeeOrBalanceRefresh() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await db.queueXrplSend(sendID:"one",plan:plan)
        let signed = try XrplSendCrypto.sign(plan,privateKey:key)
        try await db.journalXrplSignature(sendID:"one",signed:signed)
        try await db.settleXrplSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.expired))
        let expired = try await db.send("one"); XCTAssertEqual(expired?.state,"failed"); XCTAssertEqual(expired?.failureCode,"expired")
        let targets = try await db.pendingSendBalanceRefreshTargets(); XCTAssertTrue(targets.isEmpty)
        try await draft("two",wallet:2,plan:plan,db:db); try await db.queueXrplSend(sendID:"two",plan:plan)
        do { try await db.settleXrplSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.failed,fee:12,ledger:101,code:"tecUNKNOWN")); XCTFail("Conflicting terminal evidence") } catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
    }
    func testMultisigConfigurationRecoveryDoesNotCreateTransferActivity() async throws {
        let (db,folder,p) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let keys = [Data(repeating:8,count:32),Data(repeating:9,count:32)]
        let policy = try XrplMultisigPolicy(account:p.sender,required:2,signers:keys.map { try XrplSendCrypto.address(privateKey:$0) })
        for (index,kind) in ["setup","token"].enumerated() {
            let isSetup = kind == "setup"
            let plan = XrplSendPlan(network:.mainnet,sender:p.sender,recipient:p.sender,
                reference:isSetup ? "native":"USD."+p.recipient,requestedAmount:isSetup ? "0":"1000000000000000000",
                amount:isSetup ? "0":"1000000000000000000",assetDebit:"0",assetBalance:isSetup ? String(p.nativeBalance):"0",nativeBalance:p.nativeBalance,
                reserve:1_400_000,fee:isSetup ? 12:36,sequence:UInt32(42+index),firstLedger:100,lastLedger:120,
                multisig:policy,multisigSetup:isSetup ? .signerList:nil,tokenAuthorization:isSetup ? nil:true)
            try await draft(kind,plan:plan,db:db)
            try await db.queueXrplSend(sendID:kind,plan:plan)
            let signed = try isSetup ? XrplSendCrypto.sign(plan,privateKey:key):XrplMultisigCrypto.sign(plan,privateKeys:keys)
            try await db.journalXrplSignature(sendID:kind,signed:signed)
            let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
            let pending = try await reopened.pendingXrplMultisigSetup(walletID:"w1")
            XCTAssertEqual(pending?.id,kind)
            XCTAssertEqual(try JSONDecoder().decode(XrplSignedSend.self,from:XCTUnwrap(pending?.signedPayload)),signed)
            let activityCount = try await reopened.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM activity") }
            XCTAssertEqual(activityCount,0,"Signer lists and token opt-ins are not transfers")
            try await reopened.settleXrplSend(sendID:kind,receipt:.init(hash:signed.hash,outcome:.unknown))
            let stillPending = try await reopened.pendingXrplMultisigSetup(walletID:"w1")
            XCTAssertEqual(stillPending?.id,kind)
            try await reopened.settleXrplSend(sendID:kind,receipt:.init(hash:signed.hash,outcome:.confirmed,fee:plan.fee,ledger:101,code:"tesSUCCESS"))
            let settled = try await reopened.pendingXrplMultisigSetup(walletID:"w1")
            XCTAssertNil(settled)
        }
    }
    func testAccountClosurePersistsIntentAndActualSweptAmount() async throws {
        let (db,folder,p) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let plan = XrplSendPlan(network:.mainnet,sender:p.sender,recipient:p.recipient,reference:"native",
            requestedAmount:"1000000",amount:"800000",assetDebit:"800000",assetBalance:"1000000",nativeBalance:1_000_000,
            reserve:1_000_000,fee:200_000,sequence:42,firstLedger:500,lastLedger:520,recipientReserve:0,accountDeletionFee:200_000)
        try await draft("closure",plan:plan,db:db)
        try await db.queueXrplSend(sendID:"closure",plan:plan)
        let signed = try XrplSendCrypto.sign(plan,privateKey:key)
        try await db.journalXrplSignature(sendID:"closure",signed:signed)
        let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let stored = try await reopened.xrplSendPlan(sendID:"closure")
        XCTAssertEqual(stored,plan)
        do {
            try await reopened.settleXrplSend(sendID:"closure",receipt:.init(hash:signed.hash,outcome:.confirmed,fee:200_000,ledger:501,code:"tesSUCCESS"))
            XCTFail("Closure must prove actual delivery")
        } catch { XCTAssertEqual(error as? XrplSendError,.changed) }
        let receipt = XrplSendReceipt(hash:signed.hash,outcome:.confirmed,fee:200_000,ledger:501,code:"tesSUCCESS",deliveredAmount:"900000")
        try await reopened.settleXrplSend(sendID:"closure",receipt:receipt)
        try await reopened.settleXrplSend(sendID:"closure",receipt:receipt)
        let send = try await reopened.send("closure")
        XCTAssertEqual(send?.state,"confirmed");XCTAssertEqual(send?.amountAtomic,"900000")
        let amount = try await reopened.pool.read { try String.fetchOne($0,sql:"SELECT amountAtomic FROM activity WHERE transactionID=?",arguments:["xrpl:"+signed.hash]) }
        XCTAssertEqual(amount,"900000")
        let accounts = try await reopened.accounts(walletID:"w1")
        XCTAssertFalse(accounts.isEmpty,"Ledger closure must not delete the wallet or its keys")
    }

}

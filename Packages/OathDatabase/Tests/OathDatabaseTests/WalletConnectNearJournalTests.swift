import XCTest
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class WalletConnectNearJournalTests:XCTestCase {
    let key = Data(0..<32), delegate = Data(repeating:9,count:32)
    func access(_ method:String = "near_signIn") throws -> WalletConnectNearAccess {
        var fields:[String:NearJSON] = ["accounts":.array([.object(["accountId":.string("sender.testnet"),"publicKey":.string(NearSendCrypto.keyString(delegate))])])]
        if method == "near_signIn" { fields["permission"] = .object(["receiverId":.string("wrap.testnet"),"methodNames":.array([.string("ft_transfer")])]) }
        return try .init(method:method,chain:"near:testnet",account:"sender.testnet",params:JSONEncoder().encode(NearJSON.object(fields)))
    }
    func plan(_ access:WalletConnectNearAccess,nonce:UInt64 = 1) throws -> (WalletConnectNearReview,NearSignedSend) {
        let actions = try access.actions(), publicKey = try NearSendCrypto.publicKey(privateKey:key)
        let raw = NearSendCrypto.text(access.account)+Data([0])+publicKey+NearSendCrypto.le(nonce)+NearSendCrypto.text(access.account)+Data(repeating:3,count:32)+NearSendCrypto.le(UInt32(actions.count))+actions.reduce(Data(),+)
        let request = try WalletConnectNearRequest(method:"near_signTransaction",chain:access.network.walletConnectChain,account:access.account,params:JSONEncoder().encode(NearJSON.object(["transaction":WalletConnectNearRequest.buffer(raw)])))
        let review = WalletConnectNearReview(request:request,fee:"1",transactions:[try .init(raw)],createdAt:.now)
        return (review,try WalletConnectNearAccess.signed(request.sign(privateKey:key,review:review),review:review))
    }
    func fixture() async throws -> (OathDatabase,URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WCNear-"+UUID().uuidString)
        let db = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        try await db.seed(networks:[.init(id:"near",name:"NEAR",family:"account",symbol:"NEAR",decimals:24,derivationPath:"m/44'/397'/0'",logo:"near",sortOrder:0)],assets:[.init(id:"near:native",networkID:"near",reference:"native",name:"NEAR",symbol:"NEAR",decimals:24)])
        for i in 1...2 { try await db.importWalletIfNeeded(.init(id:"w\(i)",name:"Test",kind:"hd",vaultReference:"test\(i)",createdAt:1),accounts:[.init(id:"a\(i)",walletID:"w\(i)",networkID:"near",address:"sender.testnet",derivationPath:"m/44'/397'/0'")]) }
        return (db,folder)
    }
    func testDurableReplayAndGrantScope() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let access = try access(), (plan,signed) = try plan(access)
        let row = try await db.journalWalletConnectNear(id:"request1",walletID:"w1",accountID:"a1",topic:"peer1",access:access,plan:plan,signed:signed)
        let duplicate = try await db.journalWalletConnectNear(id:"request1",walletID:"w1",accountID:"a1",topic:"peer1",access:access,plan:plan,signed:signed)
        XCTAssertEqual(row.signedData,duplicate.signedData)
        let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let recovered = try await reopened.pendingWalletConnectNearSubmissions(); XCTAssertEqual(recovered.count,1)
        XCTAssertEqual(try recovered[0].decoded().2,signed)
        try await reopened.settleWalletConnectNear(row.id,outcome:.unknown)
        do { _ = try await reopened.journalWalletConnectNear(id:"other",walletID:"w2",accountID:"a2",topic:"peer2",access:access,plan:plan,signed:signed); XCTFail("Concurrent sender") } catch { XCTAssertEqual(error as? NearSendError,.busy) }
        try await reopened.settleWalletConnectNear(row.id,outcome:.confirmed)
        try await reopened.settleWalletConnectNear(row.id,outcome:.unknown)
        let state = try await reopened.walletConnectNearSubmission(row.id); XCTAssertEqual(state?.state,"confirmed")
        let grants = try await reopened.walletConnectNearGrants(walletID:"w1",accountID:"a1",topic:"peer1",chain:"near:testnet")
        XCTAssertEqual(grants,[.init(publicKey:delegate,receiver:"wrap.testnet",methodNames:["ft_transfer"])])
        let wrongPeer = try await reopened.walletConnectNearGrants(walletID:"w1",accountID:"a1",topic:"peer2",chain:"near:testnet"); XCTAssertTrue(wrongPeer.isEmpty)
        let signOut = try self.access("near_signOut"), (outPlan,outSigned) = try self.plan(signOut,nonce:2)
        do { _ = try await reopened.journalWalletConnectNear(id:"badout",walletID:"w1",accountID:"a1",topic:"peer2",access:signOut,plan:outPlan,signed:outSigned); XCTFail("Cross-session revoke") } catch { XCTAssertEqual(error as? NearSendError,.wrongOwner) }
        _ = try await reopened.journalWalletConnectNear(id:"out",walletID:"w1",accountID:"a1",topic:"peer1",access:signOut,plan:outPlan,signed:outSigned)
        try await reopened.settleWalletConnectNear("out",outcome:.confirmed)
        let after = try await reopened.walletConnectNearGrants(walletID:"w1",accountID:"a1",topic:"peer1",chain:"near:testnet"); XCTAssertTrue(after.isEmpty)
    }
    func testTamperedSignatureAndCrossWalletReuse() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let access = try access(), (plan,signed) = try plan(access)
        var bad = signed.signature; bad[0] ^= 1
        do { _ = try await db.journalWalletConnectNear(id:"bad",walletID:"w1",accountID:"a1",topic:"peer",access:access,plan:plan,signed:.init(bytes:signed.bytes,publicKey:signed.publicKey,signature:bad,hash:signed.hash)); XCTFail("Bad signature") } catch { XCTAssertEqual(error as? NearSendError,.signing) }
        _ = try await db.journalWalletConnectNear(id:"r",walletID:"w1",accountID:"a1",topic:"peer",access:access,plan:plan,signed:signed)
        do { _ = try await db.journalWalletConnectNear(id:"r",walletID:"w2",accountID:"a2",topic:"peer",access:access,plan:plan,signed:signed); XCTFail("Cross-wallet reuse") } catch { XCTAssertEqual(error as? NearSendError,.changed) }
        try await db.settleWalletConnectNear("r",outcome:.failed)
        let grants = try await db.walletConnectNearGrants(walletID:"w1",accountID:"a1",topic:"peer",chain:"near:testnet"); XCTAssertTrue(grants.isEmpty)
    }
}

extension WalletConnectNearJournalTests {
    func testNormalSendsAndAccessChangesReserveSenderAndResetErasesGrants() async throws {
        let fixture = NearSendJournalTests(), (db,folder,sendPlan) = try await fixture.fixture()
        defer { try? FileManager.default.removeItem(at:folder) }
        let access = try WalletConnectNearAccess(method:"near_signIn",chain:"near:mainnet",account:sendPlan.sender,
            params:JSONEncoder().encode(NearJSON.object(["accounts":.array([.object(["accountId":.string(sendPlan.sender),"publicKey":.string(NearSendCrypto.keyString(delegate))])]),"permission":.object(["receiverId":.string("wrap.near"),"methodNames":.array([.string("ft_transfer")])])])))
        let actions = try access.actions(), publicKey = try NearSendCrypto.publicKey(privateKey:fixture.key)
        let raw = NearSendCrypto.text(access.account)+Data([0])+publicKey+NearSendCrypto.le(UInt64(1))+NearSendCrypto.text(access.account)+Data(repeating:3,count:32)+NearSendCrypto.le(UInt32(actions.count))+actions.reduce(Data(),+)
        let request = try WalletConnectNearRequest(method:"near_signTransaction",chain:"near:mainnet",account:access.account,params:JSONEncoder().encode(NearJSON.object(["transaction":WalletConnectNearRequest.buffer(raw)])))
        let review = WalletConnectNearReview(request:request,fee:"1",transactions:[try .init(raw)],createdAt:.now)
        let signed = try WalletConnectNearAccess.signed(request.sign(privateKey:fixture.key,review:review),review:review)
        try await fixture.draft("send",plan:sendPlan,db:db); try await db.queueNearSend(sendID:"send",plan:sendPlan)
        do { _ = try await db.journalWalletConnectNear(id:"access",walletID:"w1",accountID:"a1",topic:"peer",access:access,plan:review,signed:signed); XCTFail("Queued send ignored") } catch { XCTAssertEqual(error as? NearSendError,.busy) }
        _ = try await db.transitionSend("send",from:"queued",to:"cancelled")
        _ = try await db.journalWalletConnectNear(id:"access",walletID:"w1",accountID:"a1",topic:"peer",access:access,plan:review,signed:signed)
        try await fixture.draft("next",wallet:2,plan:sendPlan,db:db)
        do { try await db.queueNearSend(sendID:"next",plan:sendPlan); XCTFail("Pending access ignored") } catch { XCTAssertEqual(error as? NearSendError,.busy) }
        try await db.settleWalletConnectNear("access",outcome:.confirmed)
        let reset = try await db.beginWalletReset()
        do { _ = try await db.journalWalletConnectNear(id:"during-reset",walletID:"w2",accountID:"a2",topic:"other",access:access,plan:review,signed:signed); XCTFail("Reset write") } catch { }
        try await db.eraseWalletData(resetID:reset)
        let stored = try await db.walletConnectNearSubmission("access"); XCTAssertNil(stored)
        let grants = try await db.walletConnectNearGrants(walletID:"w1",accountID:"a1",topic:"peer",chain:"near:mainnet"); XCTAssertTrue(grants.isEmpty)
    }
}

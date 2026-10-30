import XCTest
@testable import OathAnkr

private actor BatchProbe {
    var attempts:[String]=[],outcomes:[String:PermissionBatchExecutor.Outcome]=[:]
    var allowed=true
    func authorize()->Bool { allowed }
    func execute(_ id:String) throws {
        attempts.append(id)
        if id=="fail" { throw PermissionError.unavailable }
        if id=="gone" { throw PermissionError.alreadyRemoved }
        if id=="busy",attempts.filter({$0==id}).count<3 { throw EVMSendError.busy }
        if id=="alwaysBusy" { throw SolanaSendError.busy }
        if id=="lock" { allowed=false;throw CancellationError() }
    }
    func finish(_ id:String,_ value:PermissionBatchExecutor.Outcome) { if outcomes[id]==nil { outcomes[id]=value } }
}
final class PermissionBatchExecutorTests:XCTestCase {
    func testFailuresAndBusyNetworkDoNotBlockOthersOrRepeatSuccess() async throws {
        let p=BatchProbe()
        try await PermissionBatchExecutor.run(ids:["busy","fail","next","gone"],authorized:{await p.authorize()},
            execute:{try await p.execute($0)},finish:{id,result,_ in await p.finish(id,result)},wait:{})
        let attempts=await p.attempts,outcomes=await p.outcomes
        XCTAssertEqual(attempts,["busy","fail","next","gone","busy","busy"])
        XCTAssertEqual(outcomes["busy"],.submitted);XCTAssertEqual(outcomes["next"],.submitted)
        XCTAssertEqual(outcomes["fail"],.failed);XCTAssertEqual(outcomes["gone"],.alreadyRemoved)
    }
    func testLockPausesUnsignedWork() async throws {
        let p=BatchProbe()
        try await PermissionBatchExecutor.run(ids:["first","lock","last"],authorized:{await p.authorize()},
            execute:{try await p.execute($0)},finish:{id,result,_ in await p.finish(id,result)},wait:{})
        let attempts=await p.attempts,outcomes=await p.outcomes
        XCTAssertEqual(attempts,["first","lock"]);XCTAssertEqual(outcomes["first"],.submitted)
        XCTAssertEqual(outcomes["lock"],.paused);XCTAssertEqual(outcomes["last"],.paused)
    }
    func testDeferralsBoundedAndRetryDoesNotPretendFailure() async throws {
        let p=BatchProbe()
        try await PermissionBatchExecutor.run(ids:["alwaysBusy","other"],maximumDeferrals:2,authorized:{true},
            execute:{try await p.execute($0)},finish:{id,result,_ in await p.finish(id,result)},wait:{})
        let attempts=await p.attempts,outcomes=await p.outcomes
        XCTAssertEqual(attempts,["alwaysBusy","other","alwaysBusy"])
        XCTAssertEqual(outcomes["alwaysBusy"],.paused);XCTAssertEqual(outcomes["other"],.submitted)
    }
    func testCancellationDuringBackoffPersistsPausedItems() async throws {
        let p=BatchProbe()
        try await PermissionBatchExecutor.run(ids:["alwaysBusy"],authorized:{true},execute:{try await p.execute($0)},
            finish:{id,result,_ in await p.finish(id,result)},wait:{throw CancellationError()})
        let outcomes=await p.outcomes;XCTAssertEqual(outcomes["alwaysBusy"],.paused)
    }
    func testScopesBindWalletOwnerChainInstructionSendAndFee() throws {
        let id=UUID().uuidString,owner="0x"+String(repeating:"1",count:40)
        let removal=EVMPermissionRemoval(kind:.token,contract:"0x"+String(repeating:"2",count:40),spender:"0x"+String(repeating:"3",count:40),expected:"10")
        func scope(id:String=id,wallet:String="w",chain:String="ethereum",fee:UInt64=100)->PermissionBatchScope {
            try! .init(sendID:id,walletID:wallet,accountID:"a",network:chain,owner:owner,removal:.evm(removal),maximumFee:fee)
        }
        let approved=scope()
        XCTAssertTrue(approved.permits(scope(fee:99)))
        XCTAssertFalse(approved.permits(scope(fee:101)))
        XCTAssertFalse(approved.permits(scope(wallet:"other")))
        XCTAssertFalse(approved.permits(scope(chain:"arbitrum")))
        XCTAssertFalse(approved.permits(scope(id:UUID().uuidString)))
        let changed=try PermissionBatchScope(sendID:id,walletID:"w",accountID:"a",network:"ethereum",owner:owner,
            removal:.evm(.init(kind:.token,contract:removal.contract,spender:removal.spender,expected:"11")),maximumFee:100)
        XCTAssertFalse(approved.permits(changed))
    }
}

import XCTest
import OathDiagnostics
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
    func testJournalWriteFailureDoesNotRewriteASubmittedItemAsFailed() async throws {
        actor Journal {
            var executions: [String] = []
            var writes: [PermissionBatchExecutor.Outcome] = []
            func execute(_ id: String) { executions.append(id) }
            func finish(_ outcome: PermissionBatchExecutor.Outcome) throws {
                writes.append(outcome)
                if outcome == .submitted { throw JournalError.write }
            }
        }
        enum JournalError: Error { case write }
        let journal = Journal()
        do {
            try await PermissionBatchExecutor.run(ids: ["reviewed", "next"], authorized: { true },
                execute: { await journal.execute($0) }, finish: { _, outcome, _ in try await journal.finish(outcome) })
            XCTFail("The caller needs the persistence failure for reconciliation")
        } catch JournalError.write { }
        let attempts = await journal.executions, writes = await journal.writes
        XCTAssertEqual(attempts, ["reviewed"])
        XCTAssertEqual(writes, [.submitted])
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

private actor PermissionBatchCapture: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    var testReports: [DiagnosticEvent] { events.filter { $0.context["step"] == "permission_fee_recheck_test" } }
    var executionIDs: [String: UUID] = [:]
    var outcomes: [String: PermissionBatchExecutor.Outcome] = [:]
    func upload(_ batch: [DiagnosticEvent]) { events += batch }
    func began(_ chain: String, operation: UUID?) { executionIDs[chain] = operation }
    func finished(_ chain: String, outcome: PermissionBatchExecutor.Outcome) { outcomes[chain] = outcome }
}

final class PermissionBatchReportingTests: XCTestCase {
    func testChangedFeeProducesOneCorrelatedFailurePerNetwork() async throws {
        guard ProcessInfo.processInfo.environment["OATH_PERMISSION_DIAGNOSTIC_CAPTURE"] == "1" else {
            throw XCTSkip("Run in isolation so the process-wide diagnostics recorder belongs to this test")
        }
        let capture = PermissionBatchCapture()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        OathDiagnostics.configure(file: folder.appendingPathComponent("errors.json"), transport: capture)
        let networks = ["arbitrum", "base", "optimism"]
        try await OathDiagnostics.withStep("permission_fee_recheck_test") {
            try await PermissionBatchExecutor.run(ids: networks, networkForItem: { $0 }, authorized: { true }, execute: { network in
                await capture.began(network, operation: OathDiagnostics.operationID)
                let sendID = UUID().uuidString
                let owner = "0x" + String(repeating: "1", count: 40)
                let removal = EVMPermissionRemoval(kind: .token, contract: "0x" + String(repeating: "2", count: 40),
                                                   spender: "0x" + String(repeating: "3", count: 40), expected: "10")
                func scope(_ fee: UInt64) throws -> PermissionBatchScope {
                    try PermissionBatchScope(sendID: sendID, walletID: "fixture", accountID: "account", network: network,
                                             owner: owner, removal: .evm(removal), maximumFee: fee)
                }
                guard try scope(100).permits(scope(101)) else { throw PermissionError.changed }
                XCTFail("A fee above the approved ceiling must not pass")
            }, finish: { network, result, _ in await capture.finished(network, outcome: result) })
        }
        for _ in 0..<200 {
            if await capture.testReports.count >= networks.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await OathDiagnostics.flush()
        let reports = await capture.testReports, ids = await capture.executionIDs, outcomes = await capture.outcomes
        XCTAssertEqual(reports.count, networks.count)
        XCTAssertEqual(Set(ids.values).count, networks.count)
        for network in networks {
            let report = try XCTUnwrap(reports.first { $0.context["chain"] == network })
            XCTAssertEqual(report.component, "permissions")
            XCTAssertEqual(report.operation, "batch_revoke")
            XCTAssertEqual(report.error.message, "changed")
            XCTAssertEqual(report.operationID, ids[network])
            XCTAssertEqual(outcomes[network], .failed)
        }
    }
}

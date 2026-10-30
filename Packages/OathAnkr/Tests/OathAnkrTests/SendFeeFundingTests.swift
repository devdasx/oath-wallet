import XCTest
import OathDiagnostics
@testable import OathAnkr

@MainActor final class SendFeeFundingTests: XCTestCase {
    func testExpectedFeeValidationKeepsSendBlockedWithoutUploadingAppErrors() async throws {
        guard ProcessInfo.processInfo.environment["OATH_FEE_VALIDATION_DIAGNOSTICS_TEST"] == "1" else {
            throw XCTSkip("Run alone to isolate the process-wide diagnostics outbox")
        }
        let reports = FeeValidationReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at:file) }
        OathDiagnostics.configure(file:file,transport:reports)
        let transport = EVMSendFixtureTransport(network:.arbitrum,nativeBalance:"0")
        let client = try EVMSendClient(network:.arbitrum,endpoints:[URL(string:"https://fixture.invalid")!],transport:transport)
        do {
            _ = try await client.quote(sender:"0x" + String(repeating:"1",count:40),
                recipient:"0x" + String(repeating:"2",count:40),reference:"0x" + String(repeating:"3",count:40),
                decimals:6,amount:"100")
            XCTFail("A token send with no native fee funds must remain blocked")
        } catch {
            XCTAssertEqual(error as? SendFeeFundingError,.insufficientNativeBalance)
            // The same thrown error crosses both service and form boundaries.
            for operation in ["quote","prepare"] {
                OathDiagnostics.record(error,component:"evm_send",operation:operation,context:["chain":"arbitrum"])
            }
        }
        let broadcasts = await transport.broadcasts
        XCTAssertEqual(broadcasts,0)
        OathDiagnostics.record(EVMSendError.malformed,component:"evm_send",operation:"quote")
        OathDiagnostics.record(EVMSendError.wrongNetwork,component:"evm_send",operation:"quote")
        // An untrusted lookalike must not acquire the typed control-flow exemption.
        OathDiagnostics.record(NSError(domain:"OathAnkr.SendFeeFundingError",code:0,
            userInfo:[NSLocalizedDescriptionKey:"insufficientNativeBalance"]),component:"fixture",operation:"lookalike")
        for _ in 0..<200 {
            if await reports.events.count >= 3 { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        try await Task.sleep(for:.milliseconds(100))
        let events = await reports.events
        XCTAssertEqual(events.count,3)
        XCTAssertEqual(Set(events.map(\.error.message)),["malformed","wrongNetwork","insufficientNativeBalance"])
        XCTAssertEqual(events.filter { $0.error.domain == "OathAnkr.SendFeeFundingError" }.map(\.operation),["lookalike"])
    }
    private func change<T: Codable>(_ plan: T, _ edits: [String: Any]) throws -> T {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        for (key, value) in edits { object[key] = value }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func expectFunding(_ action: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) {
            XCTAssertEqual($0 as? SendFeeFundingError, .insufficientNativeBalance, file: file, line: line)
        }
    }

    func testEVMAndArcTokenPlansDistinguishNativeFeesFromTokenFunds() throws {
        let evm = EVMSendTests()
        for vector in try evm.vectors() where vector.reference != "native" {
            let funded = evm.plan(vector)
            try funded.validate()
            let short = try change(funded, ["nativeBalance": "0"])
            expectFunding { try short.validate() }
            let noTokens = try change(funded, ["assetBalance": "0"])
            XCTAssertThrowsError(try noTokens.validate()) { XCTAssertEqual($0 as? EVMSendError, .insufficientFunds) }
        }
        let arc = ArcSendTests()
        for vector in try arc.vectors() where vector.reference != "native" {
            let funded = arc.plan(vector)
            try funded.validate()
            let short = try change(funded, ["nativeBalance": "0"])
            expectFunding { try short.validate() }
        }
    }

    func testGRAMAndNEARTokensRequireNativeFeeFunds() throws {
        let gram = try TonSendTests.plan(token:true)
        try gram.validate()
        let noGram = try change(gram, ["nativeBalance": 0])
        expectFunding { try noGram.validate() }
        // Enough for the outer fee but not the jetton forwarding amount.
        let forwarding = try change(gram, ["nativeBalance": gram.feeReserve])
        expectFunding { try forwarding.validate() }
        let near = try NearSendTests.plan(token:true)
        try near.validate()
        let noSpendableNear = try change(near, ["nativeBalance": near.reserve])
        expectFunding { try noSpendableNear.validate() }
    }

    func testSolanaTokenFeesRemainSeparateFromRentAndTokenFunds() throws {
        let fixture = SolanaSendTests()
        for vector in try fixture.fixtures().vectors where vector.kind != "native" {
            let funded = fixture.plan(vector)
            try funded.validate()
            let noSOL = try change(funded, ["nativeBalance": 0])
            expectFunding { try noSOL.validate() }
            let noTokens = try change(funded, ["assetBalance": 0])
            XCTAssertThrowsError(try noTokens.validate()) { XCTAssertEqual($0 as? SolanaSendError, .insufficientFunds) }
        }
    }

    func testTronTokenFeeBudgetRequiresTRX() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource:"sdk-vector",withExtension:"json",subdirectory:"Fixtures/TronSend"))
        let fixture = try JSONDecoder().decode(TronJSON.self,from:Data(contentsOf:url))
        for row in try XCTUnwrap(fixture["vectors"].array) where row["reference"].string != "native" {
            let stamp = try XCTUnwrap(fixture["timestamp"].integer)
            let limit = try XCTUnwrap(row["feeLimit"].integer)
            let plan = TronSendPlan(network:.nile,sender:try XCTUnwrap(fixture["sender"].string),
                recipient:try XCTUnwrap(fixture["recipient"].string),reference:try XCTUnwrap(row["reference"].string),
                amount:"100",requestedAmount:"100",assetBalance:"10000000",decimals:6,nativeBalance:0,
                fee:limit+1_000_000,estimatedFee:limit,feeLimit:limit,energyPrice:100,bandwidthPrice:1000,
                blockID:try XCTUnwrap(fixture["blockID"].string),blockNumber:71803059,timestamp:stamp,
                expiration:stamp+180_000,createdAt:Date(timeIntervalSince1970:Double(stamp)/1000))
            expectFunding { try plan.validate(checkAge:false) }
            let funded = try change(plan, ["nativeBalance": 1_000_000_000])
            XCTAssertNoThrow(try funded.validate(checkAge:false))
        }
    }

    func testEVMRPCFeeFailureDoesNotRetryOrMisclassifyContractReverts() async throws {
        for (code, message, expectedFunding) in [
            (-32000, "insufficient funds for gas * price + value", true),
            (3, "insufficient funds for transfer", false),
            (-32000, "execution reverted: insufficient funds for transfer", false)
        ] {
            let transport = FeeRPCFixture(code:code, message:message)
            let client = try EVMSendClient(network:.ethereum,
                endpoints:[URL(string:"https://one.example")!,URL(string:"https://two.example")!],transport:transport)
            do { _ = try await client.rpc("eth_estimateGas",[]); XCTFail("Accepted rejected RPC") }
            catch { XCTAssertEqual(error is SendFeeFundingError, expectedFunding) }
            let count = await transport.count
            XCTAssertEqual(count, 1, "Deterministic fee rejection must not be retried")
        }
    }

    func testSuiTokensRequireSuiButFeeCapsAreDifferent() throws {
        let tokens = SuiSendFunds(coins:[],addressBalance:1_000_000)
        func plan(_ native: UInt64, _ budget: UInt64 = 5_000_000) throws -> SuiSendPlan {
            try .make(network:.testnet,sender:"0x1",recipient:"0x2",reference:"0x3::coin::TOKEN",amount:100,
                native:.init(coins:[],addressBalance:native),asset:tokens,gasPrice:1000,gasBudget:budget,epoch:1)
        }
        expectFunding { _ = try plan(0) }
        expectFunding { _ = try plan(4_999_999) }
        XCTAssertNoThrow(try plan(10_000_000).validate())
        XCTAssertThrowsError(try plan(UInt64.max, SuiSendPlan.maximumGasBudget+1)) {
            XCTAssertFalse($0 is SendFeeFundingError)
        }
    }

    func testEVMFundingClassifierRejectsContractRevertsAndUnknownErrors() {
        for message in ["insufficient funds for gas * price + value", "insufficient funds for gas * price + value: balance 0, tx cost 100", "insufficient balance to pay for gas"] {
            XCTAssertTrue(SendFeeFundingError.isEVMFundingMessage(message))
        }
        for message in ["execution reverted: insufficient funds for transfer", "ERC20: transfer amount exceeds balance", "insufficient funds", "out of gas", "insufficient funds for transferXYZ", String(repeating:"x",count:2049)] {
            XCTAssertFalse(SendFeeFundingError.isEVMFundingMessage(message))
        }
        XCTAssertFalse(SendFeeFundingError.isEVMFundingMessage(nil))
    }
}

private actor FeeValidationReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

private actor FeeRPCFixture: AnkrTransport {
    let code: Int, message: String
    var count = 0
    init(code: Int, message: String) { self.code=code; self.message=message }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        count += 1
        let rows: SolanaJSON = .array([
            .object(["jsonrpc":.string("2.0"),"id":.number("0"),"result":.string("0x1")]),
            .object(["jsonrpc":.string("2.0"),"id":.number("1"),"error":.object(["code":.number(String(code)),"message":.string(message)])])
        ])
        return (try JSONEncoder().encode(rows),200)
    }
}

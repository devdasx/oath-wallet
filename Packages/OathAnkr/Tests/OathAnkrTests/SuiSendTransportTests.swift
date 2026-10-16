import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor SendFixture: AnkrTransport {
    enum Mode: Sendable { case normal, wrongFallback, wrongNetwork, badOwner, failPrimary, failedSimulation, duplicateCoins, unknownBroadcast, failedExecution }
    let mode: Mode
    let sender: String
    var calls = 0, writes = 0, reconciles = 0
    var writtenBytes = Set<Data>()
    init(_ mode:Mode = .normal, sender:String) { self.mode = mode; self.sender = sender }
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        calls += 1
        let body = try JSONDecoder().decode(SuiJSON.self,from:request.httpBody!)
        let query = body["query"].string ?? ""
        if mode == .failPrimary, request.url?.host == "rpc.ankr.com" { return (Data(),503) }
        var data: [String:SuiJSON] = ["chainIdentifier":.string((mode == .wrongNetwork || mode == .wrongFallback && request.url?.host != "rpc.ankr.com") ? SuiSendNetwork.testnet.chainIdentifier:SuiSendNetwork.mainnet.chainIdentifier)]
        func effects(status:String,digest:String = "") -> SuiJSON {
            .object(["status":.string(status),"transaction":.object(["digest":.string(digest)]),"gasEffects":.object(["gasSummary":.object([
                "computationCost":.string("1000000"),"storageCost":.string("1000000"),"storageRebate":.string("500000")])]),
                "executionError":.object(["message":.string("Move execution aborted")])])
        }
        if query.contains("executeTransaction") {
            writes += 1
            writtenBytes.insert(Data(base64Encoded:body["variables"]["tx"].string!)!)
            if mode == .unknownBroadcast || mode == .wrongFallback { throw URLError(.timedOut) }
            let bytes = Data(base64Encoded:body["variables"]["tx"].string!)!
            data["executeTransaction"] = .object(["effects":effects(status:mode == .failedExecution ? "FAILURE":"SUCCESS",digest:SuiSendCrypto.digest(bytes))])
        } else if query.contains("transaction(digest:") {
            reconciles += 1; data["transaction"] = .null
        } else if query.contains("simulateTransaction") {
            data["simulateTransaction"] = .object(["effects":effects(status:mode == .failedSimulation ? "FAILURE":"SUCCESS")])
        } else if query.contains("referenceGasPrice") {
            data["epoch"] = .object(["epochId":.string("1000"),"referenceGasPrice":.string("1000")])
        } else if query.contains("address(address:") {
            let coin:SuiJSON = .object(["address":.string(try SuiIdentity.address("0x123")),"version":.string("1"),"digest":.string(SuiSendCrypto.base58(Data(repeating:1,count:32))),
                "contents":.object(["json":.object(["balance":.string("10000000")]),"type":.object(["repr":body["variables"]["objectType"]])])])
            data["checkpoint"] = .object(["sequenceNumber":.number("100")])
            data["address"] = .object(["address":.string(mode == .badOwner ? "0xabc":sender),"balance":.object(["addressBalance":.string("10000000")]),
                "objects":.object(["nodes":.array(mode == .duplicateCoins ? [coin,coin]:[coin]),"pageInfo":.object(["hasNextPage":.bool(false),"endCursor":.null])])])
        }
        return (try JSONEncoder().encode(SuiJSON.object(["data":.object(data)])),200)
    }
}
final class SuiSendTransportTests: XCTestCase {
    let key = Data(repeating:7,count:32)
    func testColdFallbackIsVerifiedBeforeReceivingSignedBytes() async throws {
        let sender=try SuiSendCrypto.address(privateKey:key),t=SendFixture(.wrongFallback,sender:sender),c=try SuiSendClient(network:.mainnet,apiKey:"testfixture",transport:t)
        let p=try await c.quote(sender:sender,recipient:"0xabc",reference:"native",amount:1_000_000),s=try SuiSendCrypto.sign(p,privateKey:key)
        let receipt=try await c.submit(s,sender:sender)
        let writes=await t.writes;XCTAssertEqual(writes,1);XCTAssertEqual(receipt.outcome,.unknown)
    }
    func testWarmEndpointSubmitsWithoutRedundantRead() async throws {
        let sender=try SuiSendCrypto.address(privateKey:key),t=SendFixture(sender:sender),c=try SuiSendClient(network:.mainnet,transport:t)
        let p=try await c.quote(sender:sender,recipient:"0xabc",reference:"native",amount:1_000_000),s=try SuiSendCrypto.sign(p,privateKey:key)
        let before=await t.calls
        let receipt=try await c.submit(s,sender:sender)
        let after=await t.calls;XCTAssertEqual(after-before,1);XCTAssertEqual(receipt.outcome,.confirmed)
    }
    func testMixedAddressAndCoinFundsSimulateWithPayableBudget() async throws {
        let sender = try SuiSendCrypto.address(privateKey:key), transport = SendFixture(sender:sender)
        let client = try SuiSendClient(network:.mainnet,transport:transport)
        let quote = try await client.quote(sender:sender,recipient:"0xabc",reference:"native",amount:12_000_000)
        XCTAssertEqual(quote.amount,12_000_000); XCTAssertEqual(quote.gasBudget,4_000_000)
        XCTAssertEqual(quote.estimatedFee,1_500_000); XCTAssertEqual(quote.withdrawal,2_000_000)
        XCTAssertNoThrow(try SuiSendCrypto.sign(quote,privateKey:key))
    }
    func testIdentityAndDuplicateCoinsFailClosed() async throws {
        let sender = try SuiSendCrypto.address(privateKey:key)
        for (mode,expected) in [(SendFixture.Mode.wrongNetwork,SuiSendError.wrongNetwork),(.badOwner,.wrongOwner),(.duplicateCoins,.malformed)] {
            let transport = SendFixture(mode,sender:sender)
            let client = try SuiSendClient(network:.mainnet,apiKey:"testfixture",transport:transport)
            do { _ = try await client.funds(owner:sender,reference:"native"); XCTFail("Invalid provider snapshot") }
            catch { XCTAssertEqual(error as? SuiSendError,expected) }
            let count = await transport.calls; XCTAssertEqual(count,1)
        }
    }
    func testPrimaryReadFailureUsesOfficialFallback() async throws {
        let sender = try SuiSendCrypto.address(privateKey:key), transport = SendFixture(.failPrimary,sender:try SuiSendCrypto.address(privateKey:key))
        let client = try SuiSendClient(network:.mainnet,apiKey:"testfixture",transport:transport)
        let funds = try await client.funds(owner:sender,reference:"native")
        XCTAssertEqual(try funds.total,20_000_000)
        let calls = await transport.calls; XCTAssertEqual(calls,2)
    }
    func testFailedSimulationNeverProducesSignableQuote() async throws {
        let sender = try SuiSendCrypto.address(privateKey:key), transport = SendFixture(.failedSimulation,sender:try SuiSendCrypto.address(privateKey:key))
        let client = try SuiSendClient(network:.mainnet,transport:transport)
        do { _ = try await client.quote(sender:sender,recipient:"0xabc",reference:"native",amount:1_000_000); XCTFail("Failed simulation quoted") }
        catch { XCTAssertEqual(error as? SuiSendError,.simulationFailed) }
        let writes = await transport.writes; XCTAssertEqual(writes,0)
    }
    func testUncertainWriteReconcilesBeforeExactByteFallback() async throws {
        let sender = try SuiSendCrypto.address(privateKey:key), transport = SendFixture(.unknownBroadcast,sender:try SuiSendCrypto.address(privateKey:key))
        let client = try SuiSendClient(network:.mainnet,apiKey:"testfixture",transport:transport)
        let quote = try await client.quote(sender:sender,recipient:"0xabc",reference:"native",amount:1_000_000)
        let signed = try SuiSendCrypto.sign(quote,privateKey:key)
        let result = try await client.submit(signed,sender:sender)
        XCTAssertEqual(result.digest,signed.digest); XCTAssertEqual(result.outcome,.unknown); XCTAssertNil(result.fee)
        let writes = await transport.writes; XCTAssertEqual(writes,2)
        let reconciles = await transport.reconciles; XCTAssertEqual(reconciles,2)
        let bytes = await transport.writtenBytes; XCTAssertEqual(bytes,[signed.bytes])
    }
    func testFailedExecutionIsDistinctFromUnknownAndSuccess() async throws {
        let sender = try SuiSendCrypto.address(privateKey:key), transport = SendFixture(.failedExecution,sender:try SuiSendCrypto.address(privateKey:key))
        let client = try SuiSendClient(network:.mainnet,transport:transport)
        let quote = try await client.quote(sender:sender,recipient:"0xabc",reference:"native",amount:1_000_000)
        let signed = try SuiSendCrypto.sign(quote,privateKey:key)
        let result = try await client.submit(signed,sender:sender)
        XCTAssertEqual(result.outcome,.failed); XCTAssertEqual(result.fee,1_500_000)
    }
    func testSigningMaterialCannotLeakThroughProviderErrorText() throws {
        let sender = try SuiSendCrypto.address(privateKey:key)
        let funds = SuiSendFunds(coins:[],addressBalance:1_000_000_000)
        let plan = try SuiSendPlan.make(network:.mainnet,sender:sender,recipient:"0xabc",reference:"native",amount:1_000_000,native:funds,asset:funds,gasPrice:1000,gasBudget:5_000_000,epoch:1000)
        let signed = try SuiSendCrypto.sign(plan,privateKey:key)
        let raw = "Rejected transaction \(signed.bytes.base64EncodedString()) signature \(signed.signature.base64EncodedString()) sender \(sender) at https://rpc.ankr.com/privatecredential"
        let filtered = DiagnosticPrivacy.text(raw)
        for value in [signed.bytes.base64EncodedString(),signed.signature.base64EncodedString(),sender,"privatecredential"] { XCTAssertFalse(filtered.contains(value)) }
    }
}

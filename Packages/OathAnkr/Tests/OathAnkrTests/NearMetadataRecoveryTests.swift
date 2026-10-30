import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor NearMetadataTransport: AnkrTransport {
    var reply: NearJSON
    var count = 0
    var active = 0, maximum = 0
    var delay: Duration = .milliseconds(20)
    init(_ reply: NearJSON) { self.reply = reply }
    func set(_ reply: NearJSON) { self.reply = reply }
    func setDelay(_ value: Duration) { delay = value }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        count += 1; active += 1; maximum = max(maximum, active)
        defer { active -= 1 }
        try await Task.sleep(for: delay)
        let data = try JSONEncoder().encode(reply)
        DiagnosticHTTP.response(data,status:200,request:request)
        return (data, 200)
    }
}

private actor NearMetadataFlowTransport: AnkrTransport {
    let history: NearJSON
    var metadataRequests = 0
    init(history: NearJSON) { self.history = history }
    func send(_ request: URLRequest) async throws -> (Data,Int) {
        let value:NearJSON
        if request.url?.host == "api.fastnear.com" {
            value = .object(["account_id":.string("root.near"), "tokens":.array([
                .object(["contract_id":.string("wrap.near"), "balance":.string("9007199254740993")]),
                .object(["contract_id":.string("broken.near"), "balance":.string("999")])])])
        } else if request.url?.host == "transfers.main.fastnear.com" { value = history }
        else {
            let call = try JSONDecoder().decode(NearJSON.self,from:request.httpBody!)
            let p = call["params"]
            if call["method"].string == "EXPERIMENTAL_genesis_config" { value = NearTests.result(.object(["chain_id":.string("mainnet")])) }
            else if call["method"].string == "block" {
                value = NearTests.result(.object(["header":.object(["hash":.string(NearTests.blockHash), "height":.number("123"),
                                                                   "timestamp_nanosec":.string("1700000000000000000")])]))
            } else if p["request_type"].string == "view_account" {
                value = NearTests.result(.object(["block_hash":.string(NearTests.blockHash), "block_height":.number("123"),
                                                 "amount":.string("100"), "locked":.string("0"), "storage_usage":.number("0")]))
            } else if p["method_name"].string == "ft_metadata" || p["account_id"].string == "broken.near" {
                if p["method_name"].string == "ft_metadata" { metadataRequests += 1 }
                value = NearTests.result(.object(["block_hash":.string(NearTests.blockHash), "block_height":.number("123"),
                    "error":.string("wasm execution failed with error: MethodResolveError(MethodNotFound)"), "logs":.array([])]))
            } else { value = try NearTests.callResult(.string("9007199254740993")) }
        }
        return (try JSONEncoder().encode(value),200)
    }
}

@MainActor final class NearMetadataFlowTests: XCTestCase {
    func testInventoryAndHistoryPreserveRawAmountsWithoutInventingMetadata() async throws {
        let file = Bundle.module.url(forResource:"ft-history-filter",withExtension:"json",subdirectory:"Fixtures/Near")!
        let history = try JSONDecoder().decode(NearJSON.self,from:Data(contentsOf:file))
        let transport = NearMetadataFlowTransport(history:history)
        let client = try NearClient(apiKey:"fixture",transport:transport)
        let inventory = try await client.inventory(owner:"root.near")
        let token = try XCTUnwrap(inventory.holdings.first { $0.reference == "wrap.near" })
        XCTAssertEqual(token.amount,"9007199254740993"); XCTAssertNil(token.token); XCTAssertNil(token.failure)
        let broken = try XCTUnwrap(inventory.holdings.first { $0.reference == "broken.near" })
        XCTAssertNil(broken.amount); XCTAssertNil(broken.token); XCTAssertEqual(broken.failure,"contractRead")
        let expected = try NearDecoding.history(history,owner:"root.near",stream:"transfers",raw:Data())
        for _ in 0..<2 {
            let page = try await client.history(owner:"root.near",stream:"transfers",limit:5)
            XCTAssertEqual(page.events.map(\.amount),expected.events.map(\.amount))
            XCTAssertEqual(page.events.map(\.id),expected.events.map(\.id))
            XCTAssertTrue(page.events.allSatisfy { $0.token == nil })
        }
        let count = await transport.metadataRequests; XCTAssertEqual(count,2,"Two contracts, one metadata read each across all pages")
    }
}

private actor NearMetadataLiveTransport: AnkrTransport {
    let transport = AnkrHTTPTransport()
    var metadataRequests = 0
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        if let body = request.httpBody,
           try JSONDecoder().decode(NearJSON.self,from:body)["params"]["method_name"].string == "ft_metadata" {
            metadataRequests += 1
        }
        return try await transport.send(request)
    }
}

@MainActor final class NearMetadataLiveTests: XCTestCase {
    func testActualMissingAndHealthyMetadataThroughBothProviders() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_LIVE_NEAR_METADATA_KEY"] else {
            throw XCTSkip("Opt-in public NEAR read-only metadata verification")
        }
        let primaryTransport = NearMetadataLiveTransport(), publicTransport = NearMetadataLiveTransport()
        let primary = try NearClient(apiKey:key,transport:primaryTransport)
        let independent = try NearClient(endpoint:URL(string:"https://rpc.mainnet.near.org")!,transport:publicTransport)
        let block = try await primary.finalBlock()
        let absent = ["16d26232ed82eefd39a8851920a5910a42543abe.v.voteagora.near",
                      "16d26232ed82eefd39a8851920a5910a42543abe.venear.dao",
                      "16d26232ed82eefd39a8851920a5910a42543abe.vt.voteagora.near"]
        for ref in absent {
            let a = try await primary.tokenIfAvailable(ref,block:block)
            let b = try await independent.tokenIfAvailable(ref,block:block)
            XCTAssertNil(a); XCTAssertNil(b)
            let repeatRead = try await primary.tokenIfAvailable(ref,block:block); XCTAssertNil(repeatRead)
        }
        for (ref,decimals) in [("wrap.near",24),("usdt.tether-token.near",6)] {
            let a = try await primary.token(ref,block:block), b = try await independent.token(ref,block:block)
            XCTAssertEqual(a,b); XCTAssertEqual(a.decimals,decimals)
            let repeatRead = try await primary.token(ref,block:block); XCTAssertEqual(a,repeatRead)
        }
        let primaryCount = await primaryTransport.metadataRequests, publicCount = await publicTransport.metadataRequests
        XCTAssertEqual(primaryCount,5); XCTAssertEqual(publicCount,5)
        print("NEAR_METADATA_LIVE providers=2 absentContracts=3 healthyContracts=2 repeatedReads=0 signing=false broadcast=false")
    }
}

private final class NearMetadataClock: @unchecked Sendable {
    let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 10000)
    func now() -> Date { lock.withLock { time } }
    func advance(_ interval: TimeInterval) { lock.withLock { time.addTimeInterval(interval) } }
}

private actor NearMetadataReports: DiagnosticTransport {
    var events:[DiagnosticEvent] = []
    func upload(_ events:[DiagnosticEvent]) async throws { self.events += events }
}

@MainActor final class NearMetadataReportingTests: XCTestCase {
    func testAbsenceIsQuietButContractFailuresRetainSafeCorrelatedDiagnostics() async throws {
        let reports = NearMetadataReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
        defer { try? FileManager.default.removeItem(at:file) }
        OathDiagnostics.configure(file:file,transport:reports)
        let block = NearBlock(hash:NearTests.blockHash,height:123,timestamp:1700000000)
        func reply(_ message:String) -> NearJSON {
            NearTests.result(.object(["block_hash":.string(block.hash),"block_height":.number("123"),
                                     "logs":.array([]),"error":.string(message)]))
        }
        let transport = NearMetadataTransport(reply(NearMetadataRecoveryTests.missingMethod))
        let client = try NearClient(apiKey:"FixtureNearKey",transport:transport)
        let id = UUID()
        try await OathDiagnostics.$operationID.withValue(id) {
            let absent = try await client.tokenIfAvailable("missing.near",block:block); XCTAssertNil(absent)
            try await Task.sleep(for:.milliseconds(100))
            let quiet = await reports.events; XCTAssertTrue(quiet.isEmpty)
            await transport.set(reply("wasm execution failed with error: HostError(GuestPanic { panic_msg: private-input.near })"))
            do { _ = try await client.tokenIfAvailable("broken.near",block:block); XCTFail() }
            catch { XCTAssertEqual(error as? NearError,.contract) }
        }
        for _ in 0..<100 {
            if await reports.events.count >= 2 { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        await OathDiagnostics.flush()
        let events = await reports.events
        XCTAssertEqual(events.count,2)
        XCTAssertTrue(events.allSatisfy { $0.operationID == id && $0.context["chain"] == "near" })
        XCTAssertTrue(events.contains { $0.operation == "provider_response" && $0.error.message == "NEAR contract execution failed" })
        let encoded = String(decoding:try JSONEncoder().encode(events),as:UTF8.self)
        for excluded in ["FixtureNearKey", "private-input.near", "broken.near", "missing.near", "panic_msg", "account_id"] {
            XCTAssertFalse(encoded.contains(excluded),excluded)
        }
    }
}

@MainActor final class NearMetadataRecoveryTests: XCTestCase {
    static let missingMethod = "wasm execution failed with error: MethodResolveError(MethodNotFound)"
    var block: NearBlock { .init(hash: NearTests.blockHash, height: 123, timestamp: 1700000000) }
    func failure(_ message: String) -> NearJSON {
        NearTests.result(.object(["block_hash": .string(NearTests.blockHash), "block_height": .number("123"),
                                 "error": .string(message), "logs": .array([])]))
    }
    func testMissingMetadataIsClassifiedAndNotRequestedRepeatedly() async throws {
        let transport = NearMetadataTransport(failure(Self.missingMethod))
        let client = try NearClient(apiKey: "fixture", transport: transport)
        for _ in 0..<3 {
            do { _ = try await client.token("missing.near", block: block); XCTFail("Cannot import without decimals") }
            catch { XCTAssertEqual(String(describing: error), "metadataUnavailable") }
        }
        let count = await transport.count
        XCTAssertEqual(count, 1)
    }
    func testContractExecutionFailureIsNotMalformedJSON() async throws {
        let transport = NearMetadataTransport(failure("wasm execution failed with error: HostError(GasExceeded)"))
        let client = try NearClient(apiKey: "fixture", transport: transport)
        do { _ = try await client.call(contract: "broken.near", method: "ft_balance_of", block: block); XCTFail() }
        catch { XCTAssertEqual(error as? NearError, .contract) }
    }
    func testConcurrentMetadataReadsUseOneRequest() async throws {
        let reply = try NearTests.callResult(.object(["spec": .string("ft-1.0.0"), "name": .string("Wrapped NEAR"),
                                                     "symbol": .string("wNEAR"), "decimals": .number("24")]))
        let transport = NearMetadataTransport(reply), block = block
        let client = try NearClient(apiKey: "fixture", transport: transport)
        try await withThrowingTaskGroup(of: NearToken.self) { group in
            for _ in 0..<8 { group.addTask { try await client.token("wrap.near", block: block) } }
            for try await token in group { XCTAssertEqual(token.decimals, 24) }
        }
        let count = await transport.count
        XCTAssertEqual(count, 1)
    }
    func testAbsentMetadataExpiresAndContractUpgradeCanRecover() async throws {
        let clock = NearMetadataClock(), transport = NearMetadataTransport(failure(Self.missingMethod))
        let client = try NearClient(endpoint:URL(string:"https://fixture.invalid")!, transport:transport, now:{ clock.now() })
        let missing = try await client.tokenIfAvailable("missing.near", block:block)
        XCTAssertNil(missing)
        clock.advance(899)
        let cached = try await client.tokenIfAvailable("missing.near", block:block)
        XCTAssertNil(cached)
        var count = await transport.count; XCTAssertEqual(count,1)
        clock.advance(1)
        await transport.set(try NearTests.callResult(.object(["spec":.string("ft-1.0.0"), "name":.string("Now supported"),
                                                            "symbol":.string("TEST"), "decimals":.number("6")])))
        let upgraded = try await client.tokenIfAvailable("missing.near", block:block)
        XCTAssertEqual(upgraded?.decimals,6)
        count = await transport.count; XCTAssertEqual(count,2)
    }
    func testAbsentResultCannotMaskWrongBlockOrInvalidEnvelope() async throws {
        let original = failure(Self.missingMethod)
        for (field, value) in [("block_height",NearJSON.number("124")), ("block_hash",.string(String(repeating:"1",count:32))),
                               ("logs",.array([.number("1")])), ("result",.array([.number("1")])),
                               ("error",.object(["message":.string(Self.missingMethod)]))] {
            guard case .object(var root) = original, case .object(var result) = root["result"]! else { return XCTFail() }
            result[field] = value; root["result"] = .object(result)
            let transport = NearMetadataTransport(.object(root))
            let client = try NearClient(apiKey:"fixture", transport:transport)
            for _ in 0..<2 {
                do { _ = try await client.tokenIfAvailable("missing.near",block:block); XCTFail(field) }
                catch { XCTAssertEqual(error as? NearError,field.hasPrefix("block_") ? .wrongBlock:.malformed,field) }
            }
            let count = await transport.count; XCTAssertEqual(count,2,"Invalid responses must not enter the absence cache")
        }
    }
    func testInvalidMetadataAndPanicsAreNeverCachedAsAbsence() async throws {
        for reply in [try NearTests.callResult(.object(["spec":.string("ft-1.0.0"), "name":.string("Token"), "symbol":.string("BAD")])),
                      failure("wasm execution failed with error: HostError(GuestPanic { panic_msg: private-fixture.near })")] {
            let transport = NearMetadataTransport(reply), client = try NearClient(apiKey:"fixture",transport:transport)
            for _ in 0..<2 {
                do { _ = try await client.tokenIfAvailable("broken.near",block:block); XCTFail() }
                catch { XCTAssertTrue([NearError.malformed,.contract].contains(error as? NearError ?? .configuration)) }
            }
            let count = await transport.count; XCTAssertEqual(count,2)
        }
    }
    func testRequiredBalanceMethodAbsenceStillFails() async throws {
        let transport = NearMetadataTransport(failure(Self.missingMethod))
        let client = try NearClient(apiKey:"fixture", transport:transport)
        do { _ = try await client.call(contract:"missing.near",method:"ft_balance_of",block:block); XCTFail() }
        catch { XCTAssertEqual(error as? NearError,.contract) }
    }
    func testCacheDoesNotCrossAnOlderOrConflictingBlock() async throws {
        let transport = NearMetadataTransport(failure(Self.missingMethod))
        let client = try NearClient(apiKey:"fixture",transport:transport)
        _ = try await client.tokenIfAvailable("missing.near",block:block)
        // A historical lookup must validate its own response instead of using a
        // later contract's absence. The fixture still returns block 123.
        for other in [NearBlock(hash:block.hash,height:122,timestamp:block.timestamp),
                      NearBlock(hash:String(repeating:"1",count:32),height:123,timestamp:block.timestamp)] {
            do { _ = try await client.tokenIfAvailable("missing.near",block:other); XCTFail() }
            catch { XCTAssertEqual(error as? NearError,.wrongBlock) }
        }
        let count = await transport.count; XCTAssertEqual(count,3)
    }
    func testDifferentTokensReadConcurrentlyAndCacheIsBounded() async throws {
        let clock = NearMetadataClock(), transport = NearMetadataTransport(failure(Self.missingMethod)), block = block
        await transport.setDelay(.milliseconds(1))
        let client = try NearClient(endpoint:URL(string:"https://fixture.invalid")!,transport:transport,now:{ clock.now() })
        try await withThrowingTaskGroup(of:Void.self) { group in
            for index in 0..<8 { group.addTask { _ = try await client.tokenIfAvailable("token\(index).near",block:block) } }
            try await group.waitForAll()
        }
        let maximum = await transport.maximum; XCTAssertGreaterThan(maximum,1); XCTAssertLessThanOrEqual(maximum,6)
        for index in 8..<270 { clock.advance(0.01); _ = try await client.tokenIfAvailable("token\(index).near",block:block) }
        _ = try await client.tokenIfAvailable("token0.near",block:block)
        let count = await transport.count; XCTAssertEqual(count,271,"Oldest entries must be evicted")
    }
    func testCancellationReleasesProducerAndWaitingConsumers() async throws {
        let transport = NearMetadataTransport(failure(Self.missingMethod)), block = block
        await transport.setDelay(.milliseconds(150))
        let client = try NearClient(apiKey:"fixture",transport:transport)
        let producer = Task { try await client.tokenIfAvailable("missing.near",block:block) }
        while await transport.count == 0 { await Task.yield() }
        let cancelled = Task { try await client.tokenIfAvailable("missing.near",block:block) }
        let survivor = Task { try await client.tokenIfAvailable("missing.near",block:block) }
        try await Task.sleep(for:.milliseconds(20)); cancelled.cancel(); producer.cancel()
        for task in [producer,cancelled] {
            do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        }
        let value = try await survivor.value; XCTAssertNil(value)
        let count = await transport.count, active = await transport.active
        XCTAssertEqual(count,2); XCTAssertEqual(active,0)
        _ = try await client.tokenIfAvailable("missing.near",block:block)
        let after = await transport.count; XCTAssertEqual(after,2)
    }
}

import XCTest
import OathDiagnostics
@testable import OathAnkr

private let arcOwner = "0x1111111111111111111111111111111111111111"
private let arcOther = "0x2222222222222222222222222222222222222222"
private let arcToken = "0x3333333333333333333333333333333333333333"
private let arcHash = "0x" + String(repeating:"a",count:64)
private func arcWord(_ value:UInt64)->String { "0x" + String(repeating:"0",count:64-String(value,radix:16).count) + String(value,radix:16) }
private func arcLabel(_ value:String)->String {
    let text = value.utf8.map { String(format:"%02x",$0) }.joined()
    return "0x" + text + String(repeating:"0",count:64-text.count)
}
private actor ArcTransport: AnkrTransport {
    let badLabels: Bool, badDecimals: Bool
    let wrongChain:Bool, badIDs:Bool, badToken:Bool, badMirror:Bool, failPrimary:Bool, reorg:Bool
    var requests:[URLRequest] = []; var reads = 0
    init(wrongChain:Bool = false,badIDs:Bool = false,badToken:Bool = false,badMirror:Bool = false,failPrimary:Bool = false,reorg:Bool = false, badLabels: Bool = false, badDecimals: Bool = false) {
        self.badLabels = badLabels; self.badDecimals = badDecimals
        self.wrongChain = wrongChain; self.badIDs = badIDs; self.badToken = badToken
        self.badMirror = badMirror; self.failPrimary = failPrimary; self.reorg = reorg
    }
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        requests.append(request)
        if failPrimary && request.url?.host?.contains("blockdaemon") == true { return (Data(),403) }
        let calls = try JSONSerialization.jsonObject(with:request.httpBody!) as! [[String:Any]]
        let rows:[[String:Any]] = calls.map { call in
            let method = call["method"] as! String, params = call["params"] as! [Any]
            let value:Any
            switch method {
            case "eth_chainId": value = wrongChain ? "0x4cef52" : "0x13b2"
            case "eth_getBlockByNumber": reads += 1; value = ["number":"0x64","hash":reorg && reads > 1 ? "0x"+String(repeating:"b",count:64):arcHash]
            case "eth_getBalance": value = "0x20000000000001"
            case "eth_call":
                let input = params[0] as! [String:Any], data = input["data"] as! String, ref = input["to"] as! String
                if ref == arcToken && ((badLabels && ["0x06fdde03", "0x95d89b41"].contains(data)) || (badDecimals && data == "0x313ce567")) {
                    return ["jsonrpc": "2.0", "id": call["id"]!, "error": ["code": 3, "message": "execution reverted"]]
                }
                if badToken && ref == arcToken && data.hasPrefix("0x70a08231") { return ["jsonrpc":"2.0","id":call["id"]!,"error":["code":-32000,"message":"execution reverted"]] }
                if data == "0x06fdde03" { value = arcLabel("Fixture") }
                else if data == "0x95d89b41" { value = arcLabel("FIX") }
                else if data == "0x313ce567" { value = arcWord(6) }
                else { value = arcWord(ref == ArcIdentity.usdc ? (badMirror ? 1:9007):123456789) }
            default: value = NSNull()
            }
            return ["jsonrpc":"2.0","id":badIDs ? 99:call["id"]!,"result":value]
        }
        let data = try JSONSerialization.data(withJSONObject:Array(rows.reversed()))
        if badLabels || badDecimals { DiagnosticHTTP.response(data, status: 200, request: request) }
        return (data,200)
    }
}
private actor ArcDiagnosticSink: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}
private actor ArcIndexTransport: AnkrTransport {
    var requests:[URLRequest] = []
    let raw:Data
    init(raw:Data) { self.raw = raw }
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        requests.append(request); return (raw,200)
    }
}
private actor ArcQuoteTransport: AnkrTransport {
    var hosts: [String] = []
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let host = request.url!.host!; hosts.append(host)
        if host == "api.coingecko.com" { return (Data(), 429) }
        if host == "coins.llama.fi" {
            return (try JSONSerialization.data(withJSONObject: ["coins": ["arc:" + arcToken:
                ["price": "1.25", "confidence": 1, "timestamp": Date().timeIntervalSince1970]]]), 200)
        }
        if host == "api.geckoterminal.com" {
            return (try JSONSerialization.data(withJSONObject: ["data": ["type": "simple_token_price",
                "attributes": ["token_prices": [arcOther: "2.50"]]]]), 200)
        }
        throw AnkrError.transport
    }
}
final class ArcTests: XCTestCase, @unchecked Sendable {
    func testAbsentLabelsPreserveBalanceAndDecimalsRemainRequired() async throws {
        let inventory = try await ArcClient(transport: ArcTransport(badLabels: true)).inventory(owner: arcOwner, references: [arcToken])
        XCTAssertTrue(inventory.complete)
        let holding = try XCTUnwrap(inventory.holdings.first { $0.token.reference == arcToken })
        XCTAssertEqual(holding.amount, "123456789")
        XCTAssertEqual(holding.token.decimals, 6)
        XCTAssertEqual(holding.token.name, "0x333333…3333")
        XCTAssertEqual(holding.token.symbol, holding.token.name)
        let failed = try await ArcClient(transport: ArcTransport(badLabels: true, badDecimals: true))
            .inventory(owner: arcOwner, references: [arcToken], tracked: [token])
        XCTAssertFalse(failed.complete)
        XCTAssertNil(failed.holdings.first { $0.token.reference == arcToken }?.amount)
        XCTAssertEqual(failed.holdings.first?.amount, "9007199254740993")
        XCTAssertFalse(DiagnosticHTTP.optionalEVMTokenLabels, "Scope must restore after the read")
    }

    func testOptionalLabelReportingThroughActualArcBatchAndOutbox() async throws {
        guard ProcessInfo.processInfo.environment["OATH_ARC_LABEL_OUTBOX_TEST"] == "1" else {
            throw XCTSkip("Run alone in a fresh process because diagnostics configures its transport once")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sink = ArcDiagnosticSink()
        OathDiagnostics.configure(file: folder.appendingPathComponent("events.json"), transport: sink)
        _ = try await ArcClient(transport: ArcTransport(badLabels: true, badDecimals: true))
            .inventory(owner: arcOwner, references: [arcToken], tracked: [token])
        var document = try JSONSerialization.jsonObject(with: history()) as! [String: Any]
        var batches = document["data"] as! [[String: Any]]
        var transactions = batches[0]["transactions"] as! [[String: Any]]
        let rejectedAddress = "private-invalid-address-fixture"
        transactions[0]["from"] = rejectedAddress
        batches[0]["transactions"] = transactions; document["data"] = batches
        XCTAssertThrowsError(try ArcClient.decodeHistory(JSONSerialization.data(withJSONObject: document),
            owner: arcOwner, from: 0, through: 101, tokens: [arcToken: token])) {
            XCTAssertEqual($0 as? AnkrError, .invalidAddress, "Keep the original validation and error type")
        }
        for _ in 0..<200 {
            if await sink.events.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        let events = await sink.events
        XCTAssertEqual(events.count, 2, "Required decimals and invalid sender remain; optional labels do not report")
        let event = try XCTUnwrap(events.first { $0.operation == "provider_response" })
        XCTAssertEqual(event.context["stage"], "token_decimals")
        XCTAssertEqual(event.context["method"], "eth_call")
        XCTAssertEqual(event.context["chain"], "arc")
        XCTAssertEqual(event.error.code, 3)
        let validation = try XCTUnwrap(events.first { $0.operation == "arc_history_validation" })
        XCTAssertEqual(validation.context["reason"], "transaction_sender")
        XCTAssertEqual(validation.error.message, "invalidAddress")
        let output = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for privateValue in [arcOwner, arcToken, rejectedAddress, "0x313ce567", "0x64"] { XCTAssertFalse(output.contains(privateValue)) }
    }
    private func history(next:Int = 101, failed:Bool = false, duplicate:Bool = false, owner:String = arcOwner) throws -> Data {
        let topic = { (address:String) in "0x" + String(repeating:"0",count:24) + address.dropFirst(2) }
        func log(_ address:String,_ index:Int,_ amount:UInt64)->[String:Any] {
            ["address":address,"block_number":100,"block_hash":arcHash,"transaction_hash":arcHash,"log_index":index,
             "data":arcWord(amount),"topic0":ArcIdentity.transferTopic,"topic1":topic(arcOther),"topic2":topic(owner),"topic3":NSNull()]
        }
        // Two distinct equal-value system transfers, one ERC-20 mirror, and
        // sub-micro-USDC native dust. All three native movements must survive.
        var logs = [log(ArcIdentity.systemEmitter,0,1_000_000_000_000_000_000), log(ArcIdentity.usdc,1,1_000_000),
                    log(ArcIdentity.systemEmitter,2,1_000_000_000_000_000_000),log(ArcIdentity.systemEmitter,3,1),log(arcToken,4,123)]
        if duplicate { logs.append(logs[0]) }
        return try JSONSerialization.data(withJSONObject:["next_block":next,"archive_height":1000,"data":[[
            "blocks":[["number":100,"hash":arcHash,"timestamp":1_700_000_000]],
            "transactions":[["hash":arcHash,"block_number":100,"block_hash":arcHash,"from":arcOther,"to":owner,
                             "status":failed ? 0:1,"gas_used":"0x5208","effective_gas_price":"0x3b9aca00"]],"logs":logs]]])
    }
    private var token:ArcToken { try! .init(reference:arcToken,name:"Fixture",symbol:"FIX",decimals:6) }
    func testNativeUSDCUnitsAndImportCanonicalization() throws {
        XCTAssertEqual(try ArcIdentity.erc20Units(native:"9007199254740993"),"9007")
        XCTAssertEqual(try ArcIdentity.erc20Units(native:"999999999999"),"0")
        XCTAssertEqual(try ArcIdentity.erc20Units(native:"1000000000000"),"1")
        XCTAssertEqual(try ArcToken(reference:ArcIdentity.usdc,name:"USD Coin",symbol:"USDC",decimals:6),.native)
        XCTAssertEqual(try ArcIdentity.reference(ArcIdentity.systemEmitter),"native")
    }
    func testPinnedBalanceBatchDeduplicatesUSDCAndCorrelatesShuffledReplies() async throws {
        let transport = ArcTransport(), client = try ArcClient(transport:transport)
        let inventory = try await client.inventory(owner:arcOwner,references:[arcToken,ArcIdentity.usdc,ArcIdentity.systemEmitter,arcToken])
        XCTAssertEqual(inventory.holdings.count,2); XCTAssertTrue(inventory.complete)
        XCTAssertEqual(inventory.holdings.first?.amount,"9007199254740993")
        XCTAssertEqual(inventory.holdings.last?.amount,"123456789")
        XCTAssertEqual(inventory.holdings.last?.token.decimals,6)
        let requests = await transport.requests
        for request in requests {
            let body = try JSONSerialization.jsonObject(with:request.httpBody!) as! [[String:Any]]
            XCTAssertEqual(body[0]["method"] as? String,"eth_chainId")
            for call in body where ["eth_call","eth_getBalance"].contains(call["method"] as! String) {
                XCTAssertEqual((call["params"] as! [Any]).last as? String,"0x64")
            }
        }
    }
    func testRevertingTokenIsUnknownAndDoesNotEraseNative() async throws {
        let inventory = try await ArcClient(transport:ArcTransport(badToken:true)).inventory(owner:arcOwner,references:[arcToken],tracked:[token])
        XCTAssertFalse(inventory.complete); XCTAssertNil(inventory.holdings.last?.amount)
        XCTAssertEqual(inventory.holdings.first?.amount,"9007199254740993")
    }
    func testFallbackStaysOnMainnetAndRejectsTestnet() async throws {
        let transport = ArcTransport(failPrimary:true)
        _ = try await ArcClient(transport:transport).inventory(owner:arcOwner,references:[])
        let requests = await transport.requests
        XCTAssertTrue(requests.contains{$0.url?.host == "rpc.drpc.mainnet.arc.io"})
        XCTAssertFalse(requests.contains{$0.url!.absoluteString.contains("testnet")})
        do { _ = try await ArcClient(transport:ArcTransport(wrongChain:true)).head(); XCTFail() }
        catch { XCTAssertEqual(error as? AnkrError,.wrongChain) }
    }
    func testMalformedBatchAndMismatchedUSDCMirrorAndBlockRejected() async throws {
        for transport in [ArcTransport(badIDs:true),ArcTransport(badMirror:true),ArcTransport(reorg:true)] {
            do { _ = try await ArcClient(transport:transport).inventory(owner:arcOwner,references:[]); XCTFail() }
            catch { XCTAssertEqual(error as? AnkrError,.invalidResponse) }
        }
    }
    func testDualEmittersDoNotDoubleCountButRepeatedTransfersAndDustRemain() throws {
        let page = try ArcClient.decodeHistory(history(),owner:arcOwner,from:0,through:101,tokens:[arcToken:token])
        XCTAssertEqual(page.events.count,4); XCTAssertEqual(page.events.filter{$0.token.reference == "native"}.count,3)
        XCTAssertTrue(page.events.contains{$0.amount == "1" && $0.token.decimals == 18})
        XCTAssertEqual(page.transactions.count,1); XCTAssertEqual(page.transactions[0].fee,"21000000000000")
        XCTAssertFalse(page.events.contains{$0.token.reference == ArcIdentity.usdc})
    }
    func testOverlappingLogSelectionsDeduplicateByLogIdentity() throws {
        let page = try ArcClient.decodeHistory(history(duplicate:true),owner:arcOwner,from:0,through:101,tokens:[arcToken:token])
        XCTAssertEqual(page.events.count,4)
    }
    func testHistoryRejectsNoProgressOutOfRangeUnrelatedAddressAndFailedLogs() throws {
        for next in [0,102] {
            XCTAssertThrowsError(try ArcClient.decodeHistory(history(next:next),owner:arcOwner,from:0,through:101,tokens:[arcToken:token]))
        }
        XCTAssertThrowsError(try ArcClient.decodeHistory(history(owner:arcToken),owner:arcOwner,from:0,through:101,tokens:[arcToken:token]))
        XCTAssertThrowsError(try ArcClient.decodeHistory(history(failed:true),owner:arcOwner,from:0,through:101,tokens:[arcToken:token]))
        XCTAssertThrowsError(try ArcClient.decodeHistory(history(),owner:arcOwner,from:0,through:101,tokens:[:]))
    }
    func testIndexAuthOnlySentToEnvioAndCursorBoundsAreExplicit() async throws {
        let transport = ArcIndexTransport(raw:try history()), client = try ArcClient(indexKey:"fixture-secret",transport:transport)
        let page = try await client.history(owner:arcOwner,from:0,through:101,known:[token])
        XCTAssertEqual(page.nextBlock,101)
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.host,"arc.hypersync.xyz")
        XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer fixture-secret")
        XCTAssertFalse(String(data:page.raw,encoding:.utf8)!.contains("fixture-secret"))
        let query = try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
        XCTAssertEqual(query["from_block"] as? Int,0); XCTAssertEqual(query["to_block"] as? Int,101)
        XCTAssertEqual((query["logs"] as? [Any])?.count,2); XCTAssertEqual((query["transactions"] as? [Any])?.count,2)
    }
    func testMissingIndexerKeyIsExplicitNotEmptySuccess() async throws {
        do { _ = try await ArcClient().history(owner:arcOwner,from:0,through:101); XCTFail() }
        catch { XCTAssertEqual(error as? AnkrError,.configurationMissing) }
    }
    func testPriceCatalogUsesArcContractsNeverTickerOrOtherChain() throws {
        let rows:[[String:Any]] = [["id":"good","platforms":["arc":arcToken]],
            ["id":"wrong-network","platforms":["ethereum":arcOther]], ["id":"usd-coin","platforms":["arc":ArcIdentity.usdc]]]
        let catalog = try ArcMarkets.decodeCatalog(JSONSerialization.data(withJSONObject:rows))
        XCTAssertEqual(catalog.ids,[arcToken:"good"])
        let now = Date(timeIntervalSince1970:1700000000)
        let raw = try JSONSerialization.data(withJSONObject:["good":["usd":"1.07","last_updated_at":1699999999]])
        let prices = try ArcMarkets.decodePrices(raw,references:[arcToken,arcOther],catalog:catalog,now:now)
        XCTAssertEqual(prices.count,1); XCTAssertEqual(prices[0].usd,"1.07")
        XCTAssertTrue(try ArcMarkets.decodePrices(raw,references:[arcToken],catalog:catalog,now:now.addingTimeInterval(4000)).isEmpty)
    }
    func testDEXRejectsOtherChainsContractsAndThinPools() throws {
        func pair(_ chain:String,_ ref:String,_ liquidity:Int)->[String:Any] {
            ["chainId":chain,"baseToken":["address":ref],"priceUsd":"2.5","liquidity":["usd":liquidity]]
        }
        let raw = try JSONSerialization.data(withJSONObject:[pair("ethereum",arcToken,100000),pair("arc",arcOther,100000),pair("arc",arcToken,1)])
        XCTAssertTrue(try ArcMarkets.decodeDEX(raw,references:[arcToken]).isEmpty)
    }
    func testMissingSystemEmitterNeverCommitsMirrorOnlyHistory() throws {
        var json = try JSONSerialization.jsonObject(with: history()) as! [String: Any]
        var batches = json["data"] as! [[String: Any]]
        batches[0]["logs"] = (batches[0]["logs"] as! [[String: Any]]).filter {
            ($0["address"] as? String) != ArcIdentity.systemEmitter
        }
        json["data"] = batches
        XCTAssertThrowsError(try ArcClient.decodeHistory(JSONSerialization.data(withJSONObject: json),
            owner: arcOwner, from: 0, through: 101, tokens: [arcToken: token])) {
            XCTAssertEqual($0 as? AnkrError, .incompleteInventory)
        }
    }
    func testEmptyIndexedRangeMakesProgressWithoutInventingActivity() throws {
        let raw = try JSONSerialization.data(withJSONObject: ["next_block": 100, "data": []])
        let page = try ArcClient.decodeHistory(raw, owner: arcOwner, from: 0, through: 101, tokens: [:])
        XCTAssertEqual(page.nextBlock, 100); XCTAssertTrue(page.events.isEmpty); XCTAssertTrue(page.transactions.isEmpty)
    }
    func testFallbackRejectsStaleLowConfidenceAndWrongContractQuotes() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for (confidence, timestamp) in [(0.89, 1_700_000_000.0), (1.0, 1_699_990_000.0), (1.0, 1_700_001_000.0)] {
            let raw = try JSONSerialization.data(withJSONObject: ["coins": ["arc:" + arcToken:
                ["price": "2", "confidence": confidence, "timestamp": timestamp]]])
            XCTAssertTrue(try ArcMarkets.decodeFallback(raw, references: [arcToken], now: now).isEmpty)
        }
        let raw = try JSONSerialization.data(withJSONObject: ["data": ["type": "simple_token_price",
            "attributes": ["token_prices": [arcOther: "2", arcToken: "0"]]]])
        XCTAssertTrue(try ArcMarkets.decodePoolPrices(raw, references: [arcToken], now: now).isEmpty)
    }
    func testQuotePipelineSurvivesRateLimitAndCombinesContractFallbacks() async throws {
        let transport = ArcQuoteTransport()
        let quotes = try await ArcMarkets(transport: transport).quotes(references: [arcToken, arcOther],
            catalog: .init(ids: [arcToken: "fixture", arcOther: "another"]))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: quotes.map { ($0.reference, $0.usd) }),
                       [arcToken: "1.25", arcOther: "2.5"])
        let hosts = await transport.hosts
        XCTAssertEqual(hosts, ["api.coingecko.com", "coins.llama.fi", "api.geckoterminal.com"])
    }
    func testLivePublicAccountBalancesMetadataAndPrices() async throws {
        guard ProcessInfo.processInfo.environment["OATH_ARC_LIVE"] == "1" else { throw XCTSkip("Opt-in public Arc mainnet reads") }
        let markets = ArcMarkets(), fresh = try? await markets.catalog(), native = try await markets.nativePrice()
        let catalog = fresh ?? .bootstrap
        if fresh == nil { print("Arc live catalog temporarily unavailable; using bundled public contract identities with live RPC balances and live prices") }
        XCTAssertEqual(native.reference,"native"); XCTAssertFalse(catalog.ids.isEmpty)
        let owners = ["0xd55273357eb916e62e7b23114312989dfee4a3db","0x8f10b468b06c6fd214b65f87778827f7d113f996","0xa4072583658fae592a3506a42431cb6316a8d40b"]
        let client = try ArcClient()
        for (index,owner) in owners.enumerated() {
            let inventory = try await client.inventory(owner:owner,references:Array(catalog.ids.keys))
            XCTAssertEqual(inventory.holdings.filter{$0.token.reference == "native"}.count,1)
            XCTAssertNotNil(inventory.holdings.first?.amount)
            let held = inventory.holdings.filter { $0.token.reference != "native" && $0.amount != nil && $0.amount != "0" }
            if index < 2 { XCTAssertFalse(held.isEmpty) }
            let refs = held.map{$0.token.reference}
            var prices:[ArcPrice] = []
            for offset in stride(from:0,to:refs.count,by:30) {
                prices += try await markets.quotes(references:Array(refs[offset..<min(offset+30,refs.count)]),catalog:catalog)
            }
            if index < 2 { XCTAssertFalse(prices.isEmpty) }
            print("Arc public account: \(held.count) nonzero catalog tokens, \(prices.count) live USD quotes; state completeness \(inventory.complete)")
        }
    }
    func testLiveEnvioHistoryWhenCredentialAvailable() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OATH_ARC_LIVE"] == "1", let path = env["OATH_ANKR_CONFIG"] else { throw XCTSkip("Opt-in Arc index test") }
        let config = try PropertyListSerialization.propertyList(from:Data(contentsOf:URL(fileURLWithPath:path)),format:nil) as! [String:String]
        guard let key = config["EnvioAPIKey"], !key.isEmpty else { throw XCTSkip("Envio API token required for archive query") }
        let client = try ArcClient(indexKey:key)
        // Public, independently RPC-observed native transfer on 2026-10-12.
        // Fixed block avoids a false failure when a fixture address goes quiet.
        let block: Int64 = 25_520_615
        let hash = "0x5e3bd81e1fdfd2c37f53682007534ef45ea67609000a69c5fe7b7da05196c524"
        let page = try await client.history(owner:"0x43d894e229a008c72e96872739719b9cfda941d5",from:block,through:block+1)
        XCTAssertEqual(page.nextBlock,block+1)
        XCTAssertTrue(page.events.contains { $0.hash == hash && $0.token.reference == "native" })
    }
}

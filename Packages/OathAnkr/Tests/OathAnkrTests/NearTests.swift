import Foundation
import XCTest
@testable import OathAnkr

private actor NearFixtureTransport:AnkrTransport {
    let handler:@Sendable (URLRequest) throws -> NearJSON
    var requests:[URLRequest] = []
    init(_ handler:@escaping @Sendable (URLRequest) throws -> NearJSON) { self.handler = handler }
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        requests.append(request); return try (JSONEncoder().encode(handler(request)),200)
    }
    func count(_ method:String) -> Int { requests.filter{(try? JSONDecoder().decode(NearJSON.self,from:$0.httpBody ?? Data())["params"]["method_name"].string) == method}.count }
}
private actor NearAsyncTransport:AnkrTransport {
    let handler:@Sendable (URLRequest) async throws -> (Data,Int)
    var urls:[URL] = []
    var active = 0, maximum = 0
    init(_ handler:@escaping @Sendable (URLRequest) async throws -> (Data,Int)) { self.handler = handler }
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        urls.append(request.url!); active += 1; maximum = max(maximum,active)
        defer { active -= 1 }; return try await handler(request)
    }
    func stats() -> (Int,Int,[URL]) { (active,maximum,urls) }
}
@MainActor final class NearTests:XCTestCase {
    nonisolated static let blockHash = "HJcKVPta9MX2cZ2wQ9jZSRxa7f6WABptK6iv98DxA3U4"
    var block:NearBlock { .init(hash:Self.blockHash,height:123,timestamp:1700000000) }
    func fixture(_ name:String) throws -> Data { try Data(contentsOf:Bundle.module.url(forResource:name,withExtension:"json",subdirectory:"Fixtures/Near")!) }
    nonisolated static func result(_ value:NearJSON) -> NearJSON { .object(["jsonrpc":.string("2.0"),"id":.number("1"),"result":value]) }
    nonisolated static func callResult(_ json:NearJSON) throws -> NearJSON {
        result(.object(["block_hash":.string(blockHash),"block_height":.number("123"),"result":.array(try JSONEncoder().encode(json).map{.number(String($0))})]))
    }
    func testIdentityAndExactUInt128Amounts() throws {
        for s in ["root.near","wrap.near","a-b_c.near",String(repeating:"a",count:64)] { XCTAssertEqual(try NearIdentity.address(s),s) }
        for s in ["Root.near","a..near","a-_b","a.","/../../x","a",String(repeating:"a",count:65)] { XCTAssertThrowsError(try NearIdentity.address(s)) }
        XCTAssertEqual(try NearIdentity.amount(.string("0009007199254740993")),"9007199254740993")
        XCTAssertEqual(try NearIdentity.amount(.string("340282366920938463463374607431768211455")),"340282366920938463463374607431768211455")
        for s in ["340282366920938463463374607431768211456","1.1","-1","1e3"] { XCTAssertThrowsError(try NearIdentity.amount(.string(s))) }
        XCTAssertThrowsError(try NearIdentity.signed(.string("170141183460469231731687303715884105727")))
    }
    func testPinnedInventoryPartialFailureKnownTokensAndMetadataCache() async throws {
        let t = NearFixtureTransport { request in
            if request.url!.host == "api.fastnear.com" { return .object(["account_id":.string("root.near"),"tokens":.array([.object(["contract_id":.string("wrap.near"),"balance":.string("123")]),.object(["contract_id":.string("broken.near"),"balance":.null])])]) }
            let p = try JSONDecoder().decode(NearJSON.self,from:request.httpBody!)["params"]
            guard p["block_id"].string == Self.blockHash else { throw NearError.wrongBlock }
            if p["request_type"].string == "view_account" { return Self.result(.object(["block_hash":.string(Self.blockHash),"block_height":.number("123"),"amount":.string("9007199254740993"),"locked":.string("7"),"storage_usage":.number("88")])) }
            if p["account_id"].string == "broken.near" { return .object(["jsonrpc":.string("2.0"),"id":.number("1"),"error":.object(["code":.number("-32000")])]) }
            if p["method_name"].string == "ft_metadata" { return try Self.callResult(.object(["spec":.string("ft-1.0.0"),"name":.string("Wrapped NEAR"),"symbol":.string("wNEAR"),"decimals":.number("24")])) }
            return try Self.callResult(.string(p["account_id"].string == "old.near" ? "0":"123"))
        }
        let client = try NearClient(apiKey:"test",transport:t)
        let value = try await client.inventory(owner:"root.near",at:block,knownReferences:["old.near"])
        XCTAssertEqual(value.holdings.count,4)
        XCTAssertEqual(value.holdings.first{$0.reference == "native"}?.amount,"9007199254741000")
        XCTAssertEqual(value.holdings.first{$0.reference == "old.near"}?.amount,"0")
        XCTAssertNil(value.holdings.first{$0.reference == "broken.near"}?.amount)
        let count = await t.count("ft_metadata"); _ = try await client.token("wrap.near",block:block)
        let after = await t.count("ft_metadata"); XCTAssertEqual(count,after)
    }
    func testMissingAccountIsZeroButProviderFailuresAreNot() async throws {
        for missing in [true,false] {
            let t = NearFixtureTransport { request in
                if request.url!.host == "api.fastnear.com" { return .object(["account_id":.string("new.near"),"tokens":.array([])]) }
                return .object(["jsonrpc":.string("2.0"),"id":.number("1"),"error":.object(["code":.number("-32000"),"data":.string(missing ? "account new.near does not exist while viewing":"timeout")])])
            }
            let client = try NearClient(apiKey:"test",transport:t)
            do { let value = try await client.inventory(owner:"new.near",at:block); XCTAssertTrue(missing); XCTAssertFalse(value.exists); XCTAssertEqual(value.liquid,"0") }
            catch { XCTAssertFalse(missing) }
        }
    }
    func testMainnetAndPinnedBlockChecks() async throws {
        let wrong = NearFixtureTransport { _ in Self.result(.object(["chain_id":.string("testnet")])) }
        do { _ = try await NearClient(apiKey:"test",transport:wrong).finalBlock(); XCTFail() } catch { XCTAssertEqual(error as? NearError,.wrongNetwork) }
        let wrongBlock = NearFixtureTransport { _ in Self.result(.object(["block_hash":.string(Self.blockHash),"block_height":.number("124")])) }
        do { _ = try await NearClient(apiKey:"test",transport:wrongBlock).account(owner:"root.near",block:block); XCTFail() } catch { XCTAssertEqual(error as? NearError,.wrongBlock) }
    }
    func testBoundedParallelReadsAndCredentialSafeFallback() async throws {
        let t = NearAsyncTransport { request in
            try await Task.sleep(for:.milliseconds(20))
            if request.url!.host == "rpc.ankr.com" { return (Data(),503) }
            let json = Self.result(.object(["block_hash":.string(Self.blockHash),"block_height":.number("123"),"amount":.string("42")]))
            return (try JSONEncoder().encode(json),200)
        }
        let client = try NearClient(apiKey:"fixturecredential",transport:t), block = block
        try await withThrowingTaskGroup(of:Void.self) { group in
            for _ in 0..<16 { group.addTask { _ = try await client.account(owner:"root.near",block:block) } }
            try await group.waitForAll()
        }
        let (active,maximum,urls) = await t.stats()
        XCTAssertEqual(active,0); XCTAssertGreaterThan(maximum,1); XCTAssertLessThanOrEqual(maximum,6)
        let fallback = urls.filter{$0.host == "rpc.mainnet.near.org"}
        XCTAssertEqual(fallback.count,16); XCTAssertTrue(fallback.allSatisfy{!$0.absoluteString.contains("fixturecredential")})
    }
    func testCancellationReleasesActiveAndQueuedRequests() async throws {
        let t = NearAsyncTransport { _ in
            try await Task.sleep(for:.milliseconds(200))
            return (try JSONEncoder().encode(Self.result(.object(["block_hash":.string(Self.blockHash),"block_height":.number("123")]))),200)
        }
        let client = try NearClient(apiKey:"test",transport:t), block = block
        let job = Task {
            try await withThrowingTaskGroup(of:Void.self) { group in
                for _ in 0..<20 { group.addTask { _ = try await client.account(owner:"root.near",block:block) } }
                try await group.waitForAll()
            }
        }
        try await Task.sleep(for:.milliseconds(40)); job.cancel()
        do { try await job.value; XCTFail("Cancelled work must not finish as a valid snapshot") } catch { XCTAssertTrue(error is CancellationError) }
        _ = try await client.account(owner:"root.near",block:block)
        let (active,maximum,_) = await t.stats(); XCTAssertEqual(active,0); XCTAssertLessThanOrEqual(maximum,6)
    }
    func testRealTransfersAndExecutionPagesPreserveExactAmounts() throws {
        for (name,stream) in [("transfers","transfers"),("ft-history-filter","transfers"),("tx","transactions")] {
            let data = try fixture(name), json = try JSONDecoder().decode(NearJSON.self,from:data)
            let page = try NearDecoding.history(json,owner:"root.near",stream:stream,raw:data)
            XCTAssertEqual(page.ids.count,5); XCTAssertNotNil(page.next)
            if name == "ft-history-filter" { XCTAssertTrue(page.events.allSatisfy{$0.reference == "wrap.near"}); XCTAssertEqual(page.events.first?.amount,"2714026876989230877866378") }
            XCTAssertThrowsError(try NearDecoding.history(json,owner:"other.near",stream:stream,raw:data))
        }
        var json = try JSONDecoder().decode(NearJSON.self,from:fixture("transfers"))
        if case .object(var obj) = json { obj["transfers"] = .array([obj["transfers"]!.array![0],obj["transfers"]!.array![0]]); json = .object(obj) }
        XCTAssertThrowsError(try NearDecoding.history(json,owner:"root.near",stream:"transfers",raw:Data()))
    }
    func testTransactionDetailBatchesAndFees() async throws {
        let index = try JSONDecoder().decode(NearJSON.self,from:fixture("tx")), details = try JSONDecoder().decode(NearJSON.self,from:fixture("tx-details"))
        let t = NearFixtureTransport { request in request.url!.path == "/v0/account" ? index:details }
        let page = try await NearClient(apiKey:"test",transport:t).history(owner:"root.near",stream:"transactions")
        XCTAssertEqual(page.executions.count,5); XCTAssertTrue(page.executions.allSatisfy{$0.fee != nil && $0.fee != "0"})
        XCTAssertTrue(page.executions.allSatisfy{$0.raw.count>1000})
    }
    func testMultipleDetailBatchesAreCompleteAndReorderedByHash() async throws {
        let hashes = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".prefix(41)).map { String(repeating:"1",count:31)+String($0) }
        let template = try JSONDecoder().decode(NearJSON.self,from:fixture("tx-details"))["transactions"].array![0]
        let index:NearJSON = .object(["resume_token":.null,"account_txs":.array(hashes.map { hash in
            .object(["account_id":.string("root.near"),"transaction_hash":.string(hash),"tx_block_height":.number("123"),"tx_block_timestamp":.string("1700000000000000000"),"is_success":.bool(true)])
        })])
        let t = NearAsyncTransport { request in
            if request.url!.path == "/v0/account" { return (try JSONEncoder().encode(index),200) }
            let requested = try JSONDecoder().decode(NearJSON.self,from:request.httpBody!)["tx_hashes"].array!.compactMap(\.string)
            guard requested.count <= 20 else { throw NearError.unsupportedBatch }
            try await Task.sleep(for:.milliseconds(30))
            let rows:[NearJSON] = requested.reversed().map { hash in
                guard case .object(var row) = template, case .object(var transaction) = row["transaction"]! else { preconditionFailure() }
                transaction["hash"] = .string(hash); row["transaction"] = .object(transaction); return .object(row)
            }
            return (try JSONEncoder().encode(NearJSON.object(["transactions":.array(rows)])),200)
        }
        let page = try await NearClient(apiKey:"test",transport:t).history(owner:"root.near",stream:"transactions")
        XCTAssertEqual(page.executions.map(\.hash),hashes); XCTAssertTrue(page.executions.allSatisfy{$0.fee != nil})
        let (_,maximum,urls) = await t.stats(); XCTAssertGreaterThan(maximum,1)
        XCTAssertEqual(urls.filter{$0.path == "/v0/transactions"}.count,3)
    }
    func testContractPriceIdentityDecimalsAndMissingQuotes() throws {
        let catalog = try NearMarkets.decodeCatalog(fixture("catalog"))
        XCTAssertTrue(catalog.contains("native")); XCTAssertEqual(catalog.ids["wrap.near"],"wrapped-near")
        let wrapped = NearToken(reference:"wrap.near",name:"Wrapped",symbol:"anything",decimals:24,logo:nil)
        let prices = try NearMarkets.decodeEcosystemPrices(fixture("ecosystem"),tokens:[wrapped,.native])
        XCTAssertEqual(prices.count,2); XCTAssertEqual(prices[0].usd,prices[1].usd)
        let wrong = NearToken(reference:"wrap.near",name:"Fake",symbol:"NEAR",decimals:6,logo:nil)
        XCTAssertTrue(try NearMarkets.decodeEcosystemPrices(fixture("ecosystem"),tokens:[wrong]).isEmpty)
        let now = Date(timeIntervalSince1970:10000)
        let data = Data("{\"near\":{\"usd\":5.5,\"last_updated_at\":9999}}".utf8)
        XCTAssertEqual(try NearMarkets.decodePrices(data,references:["native"],catalog:catalog,now:now).first?.usd,"5.5")
        XCTAssertTrue(try NearMarkets.decodePrices(data,references:["native"],catalog:catalog,now:now.addingTimeInterval(5000)).isEmpty)
    }
}

extension NearTests {
    func testLiveHistoryPagesAndExecutionDetailsReadOnly() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_LIVE_NEAR_HISTORY_KEY"] else {
            throw XCTSkip("Opt-in public NEAR history reads only")
        }
        let client = try NearClient(apiKey: key)
        for owner in ["root.near", "mob.near", "here.tg"] {
            for stream in ["transactions", "transfers"] {
                let page = try await client.history(owner: owner, stream: stream, limit: 50)
                XCTAssertFalse(page.ids.isEmpty, "Public fixture must contain history")
                if stream == "transactions" {
                    XCTAssertTrue(page.executions.allSatisfy { $0.fee != nil })
                }
                if let cursor = page.next {
                    let older = try await client.history(owner: owner, stream: stream, before: cursor, limit: 50)
                    XCTAssertTrue(Set(page.ids).isDisjoint(with: older.ids))
                }
                print("NEAR_HISTORY publicFixture=\(owner) stream=\(stream) rows=\(page.ids.count) paginated=\(page.next != nil) broadcast=false")
            }
        }
    }

    func testLivePublicAccountsTokensHistoryAndPrices() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_LIVE_NEAR_KEY"] else { throw XCTSkip("Opt-in read-only NEAR mainnet test") }
        let client = try NearClient(apiKey:key)
        let independent = try NearClient(endpoint:URL(string:"https://rpc.mainnet.near.org")!)
        let markets = NearMarkets(), catalog = try await NearMarkets().catalog()
        var allTokens:[String:NearToken] = [:], comparisons = 0
        for owner in ["root.near","mob.near","here.tg"] {
            let value = try await client.inventory(owner:owner)
            let state = try await independent.account(owner:owner,block:value.block)
            XCTAssertEqual(try NearIdentity.amount(state["amount"]),value.liquid)
            XCTAssertEqual(try NearIdentity.amount(state["locked"]),value.locked)
            XCTAssertGreaterThan(value.holdings.count,5)
            let good = value.holdings.filter{$0.reference != "native" && $0.amount != nil}
            let mismatched = good.filter{$0.indexedAmount != nil && $0.indexedAmount != $0.amount}
            // Check index differences plus a sample of current nonzero holdings
            // through a second RPC at precisely the same finalized block.
            var refs = Set(mismatched.map(\.reference))
            for h in good.filter({$0.amount != "0"}).prefix(8) { refs.insert(h.reference) }
            for ref in refs.sorted() {
                let amount = try NearIdentity.amount(await independent.call(contract:ref,method:"ft_balance_of",args:.object(["account_id":.string(owner)]),block:value.block))
                XCTAssertEqual(amount,good.first{$0.reference == ref}?.amount); comparisons += 1
            }
            for h in value.holdings { if let token = h.token, h.amount != nil, h.amount != "0" { allTokens[token.reference] = token } }
            async let transfers = client.history(owner:owner,stream:"transfers",limit:5)
            async let txs = client.history(owner:owner,stream:"transactions",limit:5)
            let (history,transactions) = try await (transfers,txs)
            XCTAssertFalse(history.events.isEmpty); XCTAssertFalse(transactions.executions.isEmpty)
            if let next = history.next {
                let older = try await client.history(owner:owner,stream:"transfers",before:next,limit:5)
                XCTAssertTrue(Set(history.ids).isDisjoint(with:older.ids))
            }
            if owner == "root.near" {
                let (data,status) = try await AnkrHTTPTransport().send(URLRequest(url:URL(string:"https://api.nearblocks.io/v1/account/root.near/txns?order=desc&page=1&per_page=5")!))
                XCTAssertEqual(status,200)
                let rows = try JSONDecoder().decode(NearJSON.self,from:data)["txns"].array ?? []
                let hashes = Set(rows.compactMap{$0["transaction_hash"].string})
                XCTAssertFalse(hashes.isDisjoint(with:transactions.executions.map(\.hash)))
            }
            print("NEAR_LIVE owner=\(owner) contracts=\(value.holdings.count-1) rpcBalances=\(good.count) indexBalanceMatches=\(good.filter{$0.indexedAmount == $0.amount}.count) partialFailures=\(value.holdings.filter{$0.amount == nil}.count) history=\(history.ids.count) executions=\(transactions.ids.count)")
        }
        let native = try await markets.nativePrice()
        let refs = allTokens.keys.filter{catalog.contains($0)}.sorted()
        var quotes:[NearPrice] = []
        for offset in stride(from:0,to:refs.count,by:30) { quotes += try await markets.prices(references:Array(refs[offset..<min(offset+30,refs.count)]),catalog:catalog) }
        let ecosystem = try await markets.ecosystemPrices(tokens:Array(allTokens.values))
        XCTAssertGreaterThan(quotes.count,5); XCTAssertGreaterThan(ecosystem.count,5)
        if let cg = quotes.first(where:{$0.reference == "native"}), let a = Double(cg.usd), let b = Double(native.usd) { XCTAssertLessThan(abs(a-b)/a,0.1) }
        var priceComparisons = 0
        for ref in ["wrap.near","usdt.tether-token.near","token.v2.ref-finance.near"] {
            if let a = quotes.first(where:{$0.reference == ref}).flatMap({Double($0.usd)}), let b = ecosystem.first(where:{$0.reference == ref}).flatMap({Double($0.usd)}) {
                XCTAssertLessThan(abs(a-b)/a,0.15); priceComparisons += 1
            }
        }
        XCTAssertGreaterThan(priceComparisons,0)
        print("NEAR_LIVE independentRPCComparisons=\(comparisons) coinGeckoQuotes=\(quotes.count) ecosystemQuotes=\(ecosystem.count) priceComparisons=\(priceComparisons)")
    }
}

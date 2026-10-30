import Foundation
import CryptoKit
import XCTest
@testable import OathAnkr

private actor StellarMock:AnkrTransport {
    var calls:[String] = []
    let handler:@Sendable(URLRequest) throws -> (Data,Int)
    init(_ handler:@escaping @Sendable(URLRequest) throws -> (Data,Int)) { self.handler = handler }
    func send(_ request:URLRequest) async throws -> (Data,Int) { calls.append(request.url!.path); return try handler(request) }
}
private actor LaggingStellarIndex: AnkrTransport {
    var calls = 0
    let recovers: Bool
    init(recovers: Bool) { self.recovers = recovers }
    func send(_ request: URLRequest) async throws -> (Data,Int) {
        calls += 1
        let body = try JSONDecoder().decode(StellarJSON.self,from:request.httpBody!)
        XCTAssertEqual(body["method"].string,"stellar_getEvents")
        XCTAssertEqual(body["params"]["endLedger"].text,"21")
        XCTAssertEqual(body["params"]["cursor"].string,"saved")
        let height = recovers && calls > 1 ? 20 : 19
        return (Data("{\"result\":{\"events\":null,\"latestLedger\":\(height)}}".utf8),200)
    }
}
final class StellarTests:XCTestCase, @unchecked Sendable {
    let owner = "GBEBCRCJ5VX7GERSGJ5XGJX7K2CHNVQB67K2KGCX7RFGMCBIIZQ5E4GY"
    let issuer = "GBDVX4VELCDSQ54KQJYTNHXAHFLBCA77ZY2USQBM4CSHTTV7DME7KALE"
    let kale = "CB23WRDQWGSP6YPMY4UV5C4OW5CBTXKYN3XEATG7KJEZCXMJBYEHOUOV"
    func data(_ name:String) throws -> Data { try Data(contentsOf:Bundle.module.url(forResource:name,withExtension:"json",subdirectory:"Fixtures/Stellar")!) }
    func json(_ name:String) throws -> StellarJSON { try JSONDecoder().decode(StellarJSON.self,from:data(name)) }
    func testStrkeyChecksumAndSACIdentity() throws {
        XCTAssertEqual(try StellarIdentity.address(owner),owner)
        XCTAssertThrowsError(try StellarIdentity.address(String(owner.dropLast())+"A"))
        XCTAssertThrowsError(try StellarIdentity.address(owner.lowercased()))
        XCTAssertEqual(try StellarIdentity.contract(code:"KALE",issuer:issuer),kale)
        XCTAssertEqual(try StellarIdentity.reference(StellarIdentity.nativeContract),"native")
        XCTAssertThrowsError(try StellarIdentity.reference(owner))
        XCTAssertThrowsError(try StellarIdentity.contract(code:"USDC/../../",issuer:issuer))
        XCTAssertNotEqual(try StellarIdentity.contract(code:"USDC",issuer:issuer),try StellarIdentity.contract(code:"USDC",issuer:owner))
    }
    func testExactAmountsAndBounds() throws {
        XCTAssertEqual(try StellarIdentity.atomic("922337203685.4775807"),"9223372036854775807")
        XCTAssertEqual(try StellarIdentity.atomic("0.0000001"),"1")
        XCTAssertEqual(try StellarIdentity.atomic("1.983257"),"19832570")
        XCTAssertThrowsError(try StellarIdentity.atomic("-1")); XCTAssertThrowsError(try StellarIdentity.atomic("0.00000001"))
        XCTAssertThrowsError(try StellarIdentity.uint("170141183460469231731687303715884105728"))
        XCTAssertEqual(try StellarIdentity.atomic("0"),"0")
    }
    func testClassicAndIndexedRealFixturesAgree() throws {
        let classic = try StellarDecoding.classicHoldings(json("sdf"),owner:owner)
        let indexed = try json("inventory")["result"]["assets"].array!.map{try StellarDecoding.indexedHolding($0,owner:owner)}
        XCTAssertEqual(Dictionary(uniqueKeysWithValues:classic.map{($0.reference,$0.amount)}),Dictionary(uniqueKeysWithValues:indexed.map{($0.reference,$0.amount)}))
        XCTAssertEqual(classic.count,2)
        XCTAssertThrowsError(try StellarDecoding.classicHoldings(json("sdf"),owner:issuer))
        XCTAssertThrowsError(try StellarDecoding.indexedHolding(json("inventory")["result"]["assets"].array![0],owner:issuer))
    }
    func testEventXDRAndSplitTransaction() throws {
        let events = try json("events")["result"]["events"].array!.compactMap{try StellarDecoding.event($0,owner:owner)}
        XCTAssertEqual(events[0].direction,"incoming"); XCTAssertEqual(events[0].reference,"native"); XCTAssertEqual(events[0].amount,"20000000")
        XCTAssertEqual(events[1].kind,"fee"); XCTAssertEqual(events[1].amount,"100")
        XCTAssertEqual(events[2].token?.reference,kale); XCTAssertEqual(events[2].token?.decimals,7)
        XCTAssertEqual(events[3].hash,events[4].hash)
        XCTAssertThrowsError(try StellarDecoding.event(json("events")["result"]["events"].array![0],owner:issuer))
    }
    func testFailedAndSpoofedEvents() throws {
        var row = try json("events")["result"]["events"].array![2].fields!
        row["inSuccessfulContractCall"] = .bool(false)
        XCTAssertNil(try StellarDecoding.event(.object(row),owner:owner))
        row["inSuccessfulContractCall"] = .bool(true); row["contractId"] = .string(StellarIdentity.nativeContract)
        XCTAssertThrowsError(try StellarDecoding.event(.object(row),owner:owner))
        row = try json("events")["result"]["events"].array![2].fields!
        row["value"] = .string(Data([0,0,0,10]+Array(repeating:UInt8(255),count:16)).base64EncodedString())
        XCTAssertThrowsError(try StellarDecoding.event(.object(row),owner:owner))
    }
    func testCatalogMatchesContractsInsteadOfSymbols() throws {
        let catalog = try StellarMarkets.decodeCatalog(data("catalog"))
        let usdc = try StellarIdentity.contract(code:"USDC",issuer:"GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN")
        XCTAssertEqual(catalog.ids[usdc],"usd-coin"); XCTAssertFalse(catalog.contains(try StellarIdentity.contract(code:"USDC",issuer:issuer)))
        XCTAssertTrue(catalog.contains("native")); XCTAssertGreaterThan(catalog.ids.count,40)
    }
    func testMemoAmountsFeeRefundsLegacyMintAndPoolCounterparties() throws {
        // Live CAP-67 memo payment from the 380-trustline public fixture.
        let memo = "AAAAEQAAAAEAAAACAAAADwAAAAZhbW91bnQAAAAAAAoAAAAAAAAAAAAAAAAAAAABAAAADwAAAAt0b19tdXhlZF9pZAAAAAAOAAAAHE93biBMTU5TICYgU3RhcnQgRWFybmluZyBYTE0="
        XCTAssertEqual(try StellarDecoding.scAmount(.string(memo)),"1")
        XCTAssertThrowsError(try StellarDecoding.scAmount(.string(String(memo.dropLast(8)))))
        let negative = Data([0,0,0,10]+Array(repeating:UInt8(255),count:15)+[249]).base64EncodedString()
        XCTAssertEqual(try StellarDecoding.scAmount(.string(negative),allowNegative:true),"-7")
        XCTAssertThrowsError(try StellarDecoding.scAmount(.string(negative)))
        var row = try json("events")["result"]["events"].array![2].fields!
        var topics = row["topic"]!.array!
        topics.insert(.string(try StellarIdentity.ownerTopic(issuer)),at:1)
        row["topic"] = .array(topics)
        XCTAssertEqual(try StellarDecoding.event(.object(row),owner:owner)?.direction,"incoming")
        XCTAssertNil(try StellarDecoding.event(.object(row),owner:issuer))
        row = try json("events")["result"]["events"].array![0].fields!
        topics = row["topic"]!.array!
        topics[1] = .string(Data(StellarIdentity.u32(18)+StellarIdentity.u32(4)+Array(repeating:UInt8(1),count:32)).base64EncodedString())
        row["topic"] = .array(topics); row["value"] = .string(memo)
        XCTAssertEqual(try StellarDecoding.event(.object(row),owner:owner)?.amount,"1")
        XCTAssertTrue(try StellarDecoding.event(.object(row),owner:owner)?.counterparty?.hasPrefix("pool:") == true)
    }
    func testContractOnlyBalancePreservesScaleAndColonInName() throws {
        var row = try json("inventory")["result"]["assets"].array![1].fields!
        row["tokenName"] = .string("Example: Token"); row["tokenDecimals"] = .number("18")
        row["balanceRawInteger"] = .string("1000000000000000001"); row["balance"] = .string("1.000000000000000001")
        let holding = try StellarDecoding.indexedHolding(.object(row),owner:owner)
        XCTAssertEqual(holding.token.decimals,18); XCTAssertNil(holding.token.assetCode)
        XCTAssertEqual(holding.amount,"1000000000000000001"); XCTAssertEqual(holding.token.name,"Example: Token")
    }
    func testInventoryMergeDoesNotLoseUnindexedTrustlines() async throws {
        let account = try data("large_classic"), full = try data("funded"), root = try data("root")
        let address = try json("large_classic")["account_id"].string!
        let mock = StellarMock { request in
            if request.httpMethod == "POST" { return (full,200) }
            return (request.url!.path.contains("accounts/") ? account:root,200)
        }
        let client = try StellarClient(endpoint:URL(string:"https://rpc.test")!,horizon:URL(string:"https://horizon.test")!,transport:mock)
        let result = try await client.inventory(owner:address)
        XCTAssertEqual(result.holdings.count,380)
        XCTAssertEqual(result.holdings.filter{$0.reference == "native"}.count,1)
    }
    func testPaginationAndProviderErrorsAreNotEmptyBalances() async throws {
        let mock = StellarMock { _ in (Data("{}".utf8),503) }
        let client = try StellarClient(endpoint:URL(string:"https://rpc.test")!,horizon:URL(string:"https://horizon.test")!,transport:mock)
        do { _ = try await client.inventory(owner:owner); XCTFail("Failed discovery must not erase cached balances") } catch {}
        do { _ = try await client.events(owner:owner,startLedger:1,endLedger:10); XCTFail() } catch {}
    }
    func testEventPaginationValidatesRangeAndRepetition() async throws {
        let events = try data("events")
        let mock = StellarMock { _ in (events,200) }
        let client = try StellarClient(endpoint:URL(string:"https://rpc.test")!,horizon:URL(string:"https://horizon.test")!,transport:mock)
        let page = try await client.events(owner:owner,startLedger:1,endLedger:64800000,limit:10)
        XCTAssertFalse(page.complete); XCTAssertNotNil(page.next)
        do { _ = try await client.events(owner:owner,startLedger:1,endLedger:64800000,cursor:page.next,limit:10); XCTFail() } catch { XCTAssertEqual(error as? StellarError,.paginationLoop) }
        do { _ = try await client.events(owner:owner,startLedger:1,endLedger:10,limit:10); XCTFail() } catch { XCTAssertEqual(error as? StellarError,.paginationLoop) }
    }
    func testHistoryBoundaryUsesEventIndexInsteadOfPriceIndex() async throws {
        let mock = StellarMock { request in
            let body = try JSONDecoder().decode(StellarJSON.self,from:request.httpBody!)
            XCTAssertEqual(body["method"].string,"stellar_getEvents")
            XCTAssertEqual(body["params"]["limit"].text,"1")
            return (Data(#"{"result":{"latestLedger":20,"events":null}}"#.utf8),200)
        }
        let client = try StellarClient(endpoint:URL(string:"https://rpc.test")!,horizon:URL(string:"https://horizon.test")!,transport:mock)
        let height = try await client.latestLedger(); XCTAssertEqual(height,20)
    }
    func testLaggingHistoryReplicaRetriesSameWindowAndCursor() async throws {
        for recovers in [true,false] {
            let mock = LaggingStellarIndex(recovers:recovers)
            let client = try StellarClient(endpoint:URL(string:"https://rpc.test")!,horizon:URL(string:"https://horizon.test")!,transport:mock)
            do {
                let page = try await client.events(owner:owner,startLedger:1,endLedger:20,cursor:"saved")
                XCTAssertTrue(recovers); XCTAssertTrue(page.complete)
                XCTAssertEqual(page.endLedger,20); XCTAssertEqual(page.next,"saved")
            } catch { XCTAssertFalse(recovers); XCTAssertEqual(error as? StellarError,.indexUnavailable) }
            let calls = await mock.calls; XCTAssertEqual(calls,recovers ? 2:3)
        }
    }
    func testCanceledHistoryRetryStopsImmediately() async throws {
        let mock = LaggingStellarIndex(recovers:false)
        let client = try StellarClient(endpoint:URL(string:"https://rpc.test")!,horizon:URL(string:"https://horizon.test")!,transport:mock)
        let task = Task { try await client.events(owner:self.owner,startLedger:1,endLedger:20,cursor:"saved") }
        while await mock.calls == 0 { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch is CancellationError {}
        let calls = await mock.calls; XCTAssertEqual(calls,1)
    }
    func testExplicitNullExhaustsHistoryButMissingFieldDoesNot() async throws {
        for payload in [#"{"latestLedger":20,"events":null}"#,#"{"latestLedger":20}"#,#"{"latestLedger":9,"events":null}"#,#"{"latestLedger":0,"events":null}"#] {
            let mock = StellarMock { _ in (Data(("{\"result\":"+payload+"}").utf8),200) }
            let client = try StellarClient(endpoint:URL(string:"https://rpc.test")!,horizon:URL(string:"https://horizon.test")!,transport:mock)
            if payload.contains("20," ) {
                let page = try await client.events(owner:owner,startLedger:1,endLedger:10,cursor:"previous")
                XCTAssertTrue(page.complete); XCTAssertEqual(page.next,"previous"); XCTAssertTrue(page.events.isEmpty)
            } else {
                do { _ = try await client.events(owner:owner,startLedger:1,endLedger:10); XCTFail() } catch { XCTAssertEqual(error as? StellarError,payload.contains("9,") ? .indexUnavailable : .incompleteHistory) }
            }
        }
    }
    func testTradePriceUsesActualVolumeAndRejectsThinOrOldData() throws {
        let now = Date(timeIntervalSince1970:1791772800)
        let native = StellarPrice(reference:"native",usd:"0.2",source:"fixture",fetchedAt:now)
        let data = Data("{\"_embedded\":{\"records\":[{\"timestamp\":\"1791770400000\",\"base_volume\":\"10000\",\"counter_volume\":\"200\",\"trade_count\":\"10\"}]}}".utf8)
        let price = try StellarMarkets.decodeTradePrice(data,reference:kale,native:native,now:now)
        XCTAssertEqual(price?.usd,"0.004")
        let later = now.addingTimeInterval(7200)
        XCTAssertThrowsError(try StellarMarkets.decodeTradePrice(data,reference:kale,native:native,now:later))
        XCTAssertNil(try StellarMarkets.decodeTradePrice(data,reference:kale,native:.init(reference:"native",usd:"0.2",source:"fixture",fetchedAt:later),now:later))
    }

    func testLiveBalancesHistoryPricesAndIndependentHorizon() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_STELLAR_LIVE_KEY"] else { throw XCTSkip("Opt-in public Stellar network check") }
        let client = try StellarClient(apiKey:key)
        let accounts = [owner,"GA222Q73DNNRWT3JWCFVJOHVBRNR2T7VMK7T52ENAOTOUO4I347DLTWZ","GA223H7O26KC7NWDEH6R4D5ITI35I4R7BH5VDLPFTSKMWH2RUZD474TJ","GAKL6IWNAFDFETXPIHBNOUVD5LSZFFPFHPCN3XLATIKGFJOMIF5R7JYV"]
        let transport = AnkrHTTPTransport()
        try await withThrowingTaskGroup(of:Void.self) { group in
            for account in accounts { group.addTask {
                let inventory = try await client.inventory(owner:account)
                let (data,status) = try await transport.send(URLRequest(url:URL(string:"https://horizon.stellar.org/accounts/"+account)!))
                XCTAssertEqual(status,200)
                let expected = try StellarDecoding.classicHoldings(JSONDecoder().decode(StellarJSON.self,from:data),owner:account)
                for holding in expected { XCTAssertEqual(inventory.holdings.first{$0.reference == holding.reference}?.amount,holding.amount) }
                XCTAssertGreaterThan(inventory.holdings.count,1)
                if account == accounts.last {
                    let contractOnly = inventory.holdings.first{$0.reference == "CAS3FL6TLZKDGGSISDBWGGPXT3NRR4DYTZD7YOD3HMYO6LTJUVGRVEAM"}
                    XCTAssertNotNil(contractOnly); XCTAssertNil(contractOnly?.token.assetCode)
                    XCTAssertNotEqual(contractOnly?.amount,"0")
                }
                print("Stellar independent Horizon: \(expected.count) classic holdings matched; \(inventory.holdings.count) total holdings")
            } }
            try await group.waitForAll()
        }
        let metadata = try await client.metadata(reference:kale,owner:owner)
        XCTAssertEqual(metadata.symbol,"KALE"); XCTAssertEqual(metadata.decimals,7)
        let empty = StellarIdentity.encode(Array(SHA256.hash(data:Data(UUID().uuidString.utf8))),version:48)
        let emptyInventory = try await client.inventory(owner:empty)
        XCTAssertFalse(emptyInventory.exists); XCTAssertEqual(emptyInventory.holdings.first{$0.reference == "native"}?.amount,"0")
        let upper = try await client.latestLedger()
        let page = try await client.events(owner:owner,startLedger:1,endLedger:upper,limit:10)
        XCTAssertFalse(page.complete); XCTAssertGreaterThan(page.events.count,0)
        let second = try await client.events(owner:owner,startLedger:1,endLedger:upper,cursor:page.next,limit:10)
        XCTAssertTrue(Set(page.events.map(\.id)).isDisjoint(with:second.events.map(\.id)))
        let markets = StellarMarkets(), catalog = try await markets.catalog()
        let native = try await markets.nativePrice(), result = try await client.price(reference:"native")
        let ankr = try XCTUnwrap(result)
        XCTAssertLessThan(abs(Double(native.usd)!/Double(ankr.usd)!-1),0.05)
        let usdc = try StellarIdentity.contract(code:"USDC",issuer:"GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN")
        let prices = try await markets.prices(references:[usdc,"native"],catalog:catalog)
        XCTAssertEqual(prices.count,2)
        let trade = try await markets.tradePrice(token:.classic(code:"KALE",issuer:issuer),native:native)
        if let trade { XCTAssertGreaterThan(Double(trade.usd)!,0); XCTAssertEqual(trade.source,"Stellar DEX 24h VWAP") }
        print("Stellar live DEX fallback: \(trade == nil ? "market below liquidity/freshness threshold":"real trade-derived quote returned")")
        print("Stellar live: disjoint event pages, Coinbase XLM and exact-contract CoinGecko USDC/XLM quotes passed")
    }
}

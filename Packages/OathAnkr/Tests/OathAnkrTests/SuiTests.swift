import Foundation
import XCTest
@testable import OathAnkr

final class SuiTests:XCTestCase,@unchecked Sendable {
    static let owner = try! SuiIdentity.address("0x1234")
    func fixture(_ name:String) throws -> Data { try Data(contentsOf:Bundle.module.url(forResource:name,withExtension:"json",subdirectory:"Fixtures/Sui")!) }
    func testCaseSensitiveMoveIdentityAndExactArithmetic() throws {
        XCTAssertEqual(try SuiIdentity.reference("0x0002::sui::SUI"),"native")
        XCTAssertEqual(try SuiIdentity.reference("0xAB::c::Coin<0x0002::sui::SUI,vector<u8>>"),"0xab::c::Coin<0x2::sui::SUI,vector<u8>>")
        XCTAssertNotEqual(try SuiIdentity.reference("0x2::sui::sui"),"native")
        for bad in ["0x1","0x1::m","0x1::m::X<>","0x1::m::X>","0x1::m::X<u8,u64","0x1::m::X<vector>","0x1::m::X<vector<u8,u64>>","0x1::m::1","0x1::m::X\"\n"] {
            XCTAssertThrowsError(try SuiIdentity.reference(bad),bad)
        }
        let n = "340282366920938463463374607431768211455"
        XCTAssertEqual(SuiIdentity.add(n,"1"),"340282366920938463463374607431768211456")
        XCTAssertEqual(SuiIdentity.add(n,"-"+n),"0")
        XCTAssertEqual(SuiIdentity.add("-9007199254740993","100"),"-9007199254740893")
        XCTAssertEqual(SuiIdentity.add("100","-999"),"-899")
    }
    func testInventoryPinsPagesAndIncludesAddressBalancesAndUnknownMetadata() async throws {
        let transport = SuiFixtureTransport()
        let client = try SuiClient(apiKey:"fixture",transport:transport)
        let value = try await client.inventory(owner:Self.owner,pageSize:1)
        XCTAssertEqual(value.checkpoint,100)
        XCTAssertEqual(value.holdings.count,3)
        XCTAssertEqual(value.holdings.first{$0.reference=="native"}?.amount,"9007199254740993")
        XCTAssertEqual(value.holdings.first{$0.reference=="native"}?.coinBalance,"0")
        XCTAssertNil(value.holdings.first{$0.reference=="0x3::test::Unknown"}?.token)
        let requests = await transport.requests
        XCTAssertEqual(requests.filter{$0["query"].string?.contains("balances(first") == true}.count,2)
        for request in requests where request["query"].string?.contains("balances(first") == true {
            XCTAssertEqual(request["variables"]["checkpoint"].integer,100)
        }
    }
    func testGraphQLErrorsPartialDataAndWrongNetworkNeverBecomeEmptySuccess() async throws {
        for mode in ["graphql","wrongOwner","wrongChain","loop","inconsistent"] {
            let client = try SuiClient(apiKey:"fixture",transport:SuiFixtureTransport(mode:mode))
            do { _ = try await client.inventory(owner:Self.owner); XCTFail(mode) } catch {}
        }
    }
    func testLargeMetadataSetsUseSmallBoundedBatchesAndCacheMissingTypes() async throws {
        let transport = SuiFixtureTransport()
        let client = try SuiClient(apiKey:"fixture",transport:transport)
        let refs = (0..<29).map{"0x3::m::T\($0)"}
        _ = try await client.metadata(references:refs)
        let first = await transport.requests
        XCTAssertEqual(first.count,4)
        for request in first { XCTAssertLessThanOrEqual(request["variables"].fields?.count ?? 0,8) }
        _ = try await client.metadata(references:refs)
        let second = await transport.requests; XCTAssertEqual(second.count,4)
    }
    func testHistoryReducesPageSizeOnProviderBudgetLimit() async throws {
        let transport = SuiFixtureTransport(mode:"historyBudget")
        let client = try SuiClient(apiKey:"fixture",transport:transport)
        let page = try await client.history(owner:Self.owner,limit:25)
        XCTAssertTrue(page.transactions.isEmpty)
        let sizes = await transport.requests.map{$0["variables"]["size"].integer}
        XCTAssertEqual(sizes,[25,12,6,3,1])
    }
    func testFallbackDoesNotForwardAnkrCredential() async throws {
        let transport = SuiFixtureTransport(mode:"fallback")
        let client = try SuiClient(apiKey:"fixtureSecret",transport:transport)
        _ = try await client.checkpoint()
        let urls = await transport.urls
        XCTAssertEqual(urls.map(\.host),["rpc.ankr.com","graphql.mainnet.sui.io"])
        XCTAssertFalse(urls.last!.absoluteString.contains("fixtureSecret"))
    }
    func transaction(owner:String = SuiTests.owner, sponsor:String? = nil, delta:String = "-105", success:Bool = true, rebate:Int = 0) -> SuiJSON {
        .object(["digest":.string(String(repeating:"A",count:43)),"sender":.object(["address":.string(owner)]),
                 "gasInput":.object(["gasSponsor":.object(["address":.string(sponsor ?? owner)])]),
                 "effects":.object(["status":.string(success ? "SUCCESS":"FAILURE"),"timestamp":.string("2026-10-12T01:00:00.000Z"),
                    "checkpoint":.object(["sequenceNumber":.number("100")]),
                    "gasEffects":.object(["gasSummary":.object(["computationCost":.number("5"),"storageCost":.number("0"),"storageRebate":.number(String(rebate))])]),
                    "balanceChangesJson":.array([.object(["address":.string(owner),"coinType":.string(SuiIdentity.coin),"amount":.string(delta)])])])])
    }
    func testTransferGasSponsorFailureAndStorageRebate() throws {
        let tokens = ["native":SuiToken.native]
        let outgoing = try SuiDecoding.transaction(transaction(),owner:Self.owner,tokens:tokens)
        XCTAssertEqual(outgoing.movements[0].amount,"100"); XCTAssertEqual(outgoing.movements[0].direction,"outgoing"); XCTAssertEqual(outgoing.fee,"5")
        let sponsored = try SuiDecoding.transaction(transaction(sponsor:"0x999",delta:"-100"),owner:Self.owner,tokens:tokens)
        XCTAssertEqual(sponsored.movements[0].amount,"100"); XCTAssertNil(sponsored.fee)
        let failure = try SuiDecoding.transaction(transaction(delta:"-5",success:false),owner:Self.owner,tokens:tokens)
        XCTAssertTrue(failure.failed); XCTAssertEqual(failure.movements[0].amount,"0")
        let rebate = try SuiDecoding.transaction(transaction(delta:"95",rebate:100),owner:Self.owner,tokens:tokens)
        XCTAssertEqual(rebate.netGas,"-95"); XCTAssertEqual(rebate.movements[0].amount,"0"); XCTAssertEqual(rebate.fee,"0")
    }
    func testReceiptPartiesExcludeSponsorFeesAndRebates() throws {
        let recipient = try SuiIdentity.address("0x222"), sponsor = try SuiIdentity.address("0x333")
        for rebate in [0, 100] {
            var raw = transaction(sponsor: sponsor, delta: "-100", rebate: rebate).fields!
            var effects = raw["effects"]!.fields!
            effects["balanceChangesJson"] = .array([
                .object(["address": .string(Self.owner), "coinType": .string(SuiIdentity.coin), "amount": .string("-100")]),
                .object(["address": .string(recipient), "coinType": .string(SuiIdentity.coin), "amount": .string("100")]),
                .object(["address": .string(sponsor), "coinType": .string(SuiIdentity.coin), "amount": .string(String(rebate - 5))])
            ])
            raw["effects"] = .object(effects)
            let value = try SuiDecoding.transaction(.object(raw), owner: Self.owner, tokens: ["native": .native])
            let parties = try SuiDecoding.parties(value)
            XCTAssertEqual(parties.from, [Self.owner]); XCTAssertEqual(parties.to, [recipient])
        }
    }
    func testCapturedLiveReceiptsKeepExactNetChangesAndRawDetails() throws {
        let json = try JSONDecoder().decode(SuiJSON.self,from:fixture("live-history"))
        let owner = "0x39ee291682e829771ad0c3ed46ebc69a962b7c2f9e6477409b22616bcf21ac34"
        var count = 0, tokens = Set<String>()
        for edge in json["data"]["transactions"]["edges"].array! {
            let tx = try SuiDecoding.transaction(edge["node"],owner:owner,tokens:["native":.native])
            XCTAssertFalse(tx.raw.isEmpty); XCTAssertGreaterThan(tx.checkpoint,0)
            count += 1; tokens.formUnion(tx.movements.map(\.reference))
        }
        XCTAssertEqual(count,5); XCTAssertFalse(tokens.isEmpty)
    }
    func testCatalogueAndContractMatchedQuotesRejectStaleOrWrongChainPrices() throws {
        let catalog = try SuiMarkets.decodeCatalog(fixture("catalog"))
        XCTAssertGreaterThan(catalog.ids.count,100)
        let refs = Set(catalog.ids.keys)
        let dex = try SuiMarkets.decodeDexPrices(fixture("live-dex"),references:refs)
        XCTAssertGreaterThanOrEqual(dex.count,3)
        let gecko = try SuiMarkets.decodePrices(fixture("live-prices"),references:refs,catalog:catalog,now:Date(timeIntervalSince1970:1791768060))
        XCTAssertEqual(gecko.count,4)
        XCTAssertTrue(try SuiMarkets.decodePrices(fixture("live-prices"),references:refs,catalog:catalog,now:Date(timeIntervalSince1970:1791768060+7200)).isEmpty)
        let fake = Data(#"[{"chainId":"ethereum","baseToken":{"address":"0x2::sui::SUI"},"priceUsd":"900","liquidity":{"usd":999999}}]"#.utf8)
        XCTAssertTrue(try SuiMarkets.decodeDexPrices(fake,references:["native"]).isEmpty)
    }
    func testLiveFundedAccountsAgainstIndependentSameCheckpointAndPrices() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_LIVE_SUI_KEY"] else { throw XCTSkip("Opt-in read-only mainnet verification") }
        let client = try SuiClient(apiKey:key), independent = SuiClient(publicProvider:true)
        let markets = SuiMarkets(), catalog = try await markets.catalog()
        let owners = [
            "0x39ee291682e829771ad0c3ed46ebc69a962b7c2f9e6477409b22616bcf21ac34",
            "0x42960e77d87a60d0a0599757beb320147510933c5e63a6ccfec3fdd54aa796fc",
            "0x6be20abe12a8e930fd8da5120fcb392753ef7b57b43401417aedaadeb1106ec4"
        ]
        var allRefs:Set<String> = ["native"]
        for owner in owners {
            async let a = client.checkpoint(); async let b = independent.checkpoint()
            let cp = try await min(a,b)
            async let main = client.inventory(owner:owner,atCheckpoint:cp,pageSize:20)
            async let other = independent.inventory(owner:owner,atCheckpoint:cp,pageSize:20)
            let (value,expected) = try await (main,other)
            let amounts = Dictionary(uniqueKeysWithValues:value.holdings.map{($0.reference,$0.amount)})
            XCTAssertEqual(amounts,Dictionary(uniqueKeysWithValues:expected.holdings.map{($0.reference,$0.amount)}))
            XCTAssertGreaterThan(amounts.count,1)
            XCTAssertNotEqual(amounts["native"],"0")
            allRefs.formUnion(value.holdings.filter{catalog.contains($0.reference)}.map(\.reference))
            async let page = client.history(owner:owner,beforeCheckpoint:cp+1,limit:5)
            async let expectedPage = independent.history(owner:owner,beforeCheckpoint:cp+1,limit:5)
            let (history,otherHistory) = try await (page,expectedPage)
            XCTAssertEqual(history.transactions.map(\.hash),otherHistory.transactions.map(\.hash))
            XCTAssertFalse(history.transactions.isEmpty)
            if let next = history.next {
                let older = try await client.history(owner:owner,before:next,beforeCheckpoint:cp+1,limit:5)
                XCTAssertTrue(Set(older.transactions.map(\.hash)).isDisjoint(with:history.transactions.map(\.hash)))
            }
            print("SUI_LIVE holdings=\(amounts.count) exactMatches=\(amounts.count) receipts=\(history.transactions.count) checkpoint=\(cp)")
        }
        print("SUI_LIVE stage=marketQuotes")
        let native = try await markets.nativePrice()
        let refs = Array(allRefs).sorted()
        var quotes:[SuiPrice] = []
        for offset in stride(from:0,to:refs.count,by:30) { quotes += try await markets.prices(references:Array(refs[offset..<min(offset+30,refs.count)]),catalog:catalog) }
        XCTAssertGreaterThan(quotes.count,2)
        let cg = try XCTUnwrap(quotes.first{$0.reference=="native"})
        XCTAssertLessThan(abs(Decimal(string:native.usd)!-Decimal(string:cg.usd)!)/Decimal(string:native.usd)!,Decimal(string:"0.05")!)
        let compareRefs = ["native"] + catalog.ids.filter{["usd-coin","deep","cetus-protocol"].contains($0.value)}.keys.sorted()
        let dex = try await markets.dexPrices(references:compareRefs)
        let cgPrices = try await markets.prices(references:compareRefs,catalog:catalog)
        XCTAssertGreaterThanOrEqual(dex.count,3)
        for d in dex { if let c = cgPrices.first(where:{$0.reference==d.reference}) {
            XCTAssertLessThan(abs(Decimal(string:d.usd)!-Decimal(string:c.usd)!)/Decimal(string:c.usd)!,Decimal(string:"0.10")!)
        }}
        print("SUI_LIVE quotedHoldings=\(quotes.count) independentPriceMatches=\(dex.count)")
    }
}
private actor SuiFixtureTransport:AnkrTransport {
    let mode:String
    var requests:[SuiJSON] = []; var urls:[URL] = []
    init(mode:String = "") { self.mode = mode }
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        let body = try JSONDecoder().decode(SuiJSON.self,from:request.httpBody!)
        requests.append(body); urls.append(request.url!)
        if mode == "fallback", request.url!.host == "rpc.ankr.com" { return (Data(),503) }
        var value:[String:SuiJSON] = ["chainIdentifier":.string(mode == "wrongChain" ? "testnet":SuiIdentity.mainnet)]
        if mode == "historyBudget" {
            if (body["variables"]["size"].integer ?? 0) > 2 {
                return (try JSONEncoder().encode(SuiJSON.object(["errors":.array([.object(["extensions":.object(["code":.string("RESOURCE_EXHAUSTED")])])])])),200)
            }
            value["transactions"] = .object(["edges":.array([]),"pageInfo":.object(["hasPreviousPage":.bool(false),"startCursor":.null])])
            return (try JSONEncoder().encode(SuiJSON.object(["data":.object(value)])),200)
        }
        if body["query"].string!.contains("balances(first") {
            let first = body["variables"]["after"].isNull
            let rows:SuiJSON
            if first {
                rows = .array([.object(["coinType":.object(["repr":.string(SuiIdentity.coin)]),"totalBalance":.string(mode == "inconsistent" ? "1":"9007199254740993"),"coinBalance":.string("0"),"addressBalance":.string("9007199254740993")])])
            } else {
                rows = .array(["0x3::test::Known","0x3::test::Unknown"].map{ref in .object([
                    "coinType":.object(["repr":.string(ref)]),"totalBalance":.string("20"),"coinBalance":.string("10"),"addressBalance":.string("10"),
                    "coinMetadata":ref.hasSuffix("Known") ? .object(["name":.string("Known"),"symbol":.string("KN"),"decimals":.number("6")]):.null])})
            }
            value["address"] = .object(["address":.string(mode == "wrongOwner" ? "0x9":SuiTests.owner),
                "balances":.object(["nodes":rows,"pageInfo":.object(["hasNextPage":.bool(first || mode=="loop"),"endCursor":.string("second")])])])
        } else { value["checkpoint"] = .object(["sequenceNumber":.number("100")]) }
        var result:[String:SuiJSON] = ["data":.object(value)]
        if mode == "graphql" { result["errors"] = .array([.object(["message":.string("partial data")])]) }
        return (try JSONEncoder().encode(SuiJSON.object(result)),200)
    }
}

import Foundation
import XCTest
@testable import OathAnkr

final class TronTests: XCTestCase, @unchecked Sendable {
    static let owner = "TJmmqjb1DK9TTZbQXzRQ2AuA94z4gKAPFh" // TRON's public integration example.
    func fixture(_ name: String) throws -> Data { try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/Tron")!) }
    func json(_ name: String) throws -> TronJSON { try JSONDecoder().decode(TronJSON.self, from: fixture(name)) }
    func testAddressChecksumAndExact256BitQuantities() throws {
        let owner = Self.owner
        XCTAssertEqual(try TronIdentity.address("41608f8da72479edc7dd921e4c30bb7e7cddbe722e"),owner)
        XCTAssertEqual(try TronIdentity.address(TronIdentity.callAddress(owner)),owner)
        XCTAssertThrowsError(try TronIdentity.bytes(String(owner.dropLast())+"1"))
        XCTAssertEqual(try TronIdentity.uint256(String(repeating:"f",count:64)),"115792089237316195423570985008687907853269984665640564039457584007913129639935")
        XCTAssertEqual(try TronIdentity.quantity(.number("9007199254740993")),"9007199254740993")
        XCTAssertThrowsError(try TronIdentity.quantity(.string("-1")))
    }
    func testLiveUSDTZeroReturnWordStillHasExactSuccessfulTransfer() throws {
        let body = try json("ankr-tx"), receipt = try json("ankr-receipt")
        let tx = try TronDecoding.transaction(hash: body["txID"].string!, body: body, receipt: receipt)
        XCTAssertFalse(tx.failed); XCTAssertEqual(tx.events.count,1)
        XCTAssertEqual(tx.events[0].reference,TronIdentity.usdt)
        XCTAssertEqual(tx.events[0].to,Self.owner); XCTAssertEqual(tx.events[0].amount,"1000000")
        XCTAssertEqual(tx.events[0].index,1000)
    }
    func testRevertsApprovalsAndNFTLogsDoNotInventFungibleTransfers() throws {
        let body = try json("ankr-tx")
        var receipt = try XCTUnwrap(json("ankr-receipt").fields)
        receipt["receipt"] = .object(["result":.string("REVERT")])
        let tx = try TronDecoding.transaction(hash:body["txID"].string!,body:body,receipt:.object(receipt))
        XCTAssertTrue(tx.failed); XCTAssertTrue(tx.events.isEmpty)
        receipt["receipt"] = .object(["result":.string("SUCCESS")])
        var log = try XCTUnwrap(receipt["log"]?.array?.first?.fields)
        var topics = log["topics"]!.array!; topics.append(.string(String(repeating:"0",count:64))); log["topics"] = .array(topics)
        receipt["log"] = .array([.object(log)])
        XCTAssertTrue(try TronDecoding.transaction(hash:body["txID"].string!,body:body,receipt:.object(receipt)).events.isEmpty)
        receipt["log"] = .object([:])
        XCTAssertThrowsError(try TronDecoding.transaction(hash:body["txID"].string!,body:body,receipt:.object(receipt)))
    }
    func testCatalogSupportsTRC10AndContractPricesAreChainScoped() throws {
        let catalog = try TronMarkets.decodeCatalog(fixture("catalog"))
        XCTAssertEqual(catalog[TronIdentity.usdt]?.decimals,6)
        XCTAssertEqual(catalog["1002000"]?.decimals,6)
        let data = Data("""
        [{"chainId":"ethereum","baseToken":{"address":"\(TronIdentity.usdt)"},"priceUsd":"9999","liquidity":{"usd":100000000}},
        {"chainId":"tron","baseToken":{"address":"\(TronIdentity.usdt)"},"priceUsd":"1.001","liquidity":{"usd":100000}},
        {"chainId":"tron","baseToken":{"address":"\(TronIdentity.usdt)"},"priceUsd":"999","liquidity":{"usd":1}}]
        """.utf8)
        XCTAssertEqual(try TronMarkets.decodePrices(data,mints:[TronIdentity.usdt]).first?.usd,"1.001")
    }
    func testHistoricTRC10NamesResolveAndFinalityUsesSolidHeight() throws {
        let hash=String(repeating:"c",count:64), legacy="6c6567616379"
        let body=TronJSON.object(["txID":.string(hash),"ret":.array([.object(["contractRet":.string("SUCCESS")])]),"raw_data":.object(["contract":.array([.object(["type":.string("TransferAssetContract"),"parameter":.object(["value":.object(["owner_address":.string(Self.owner),"to_address":.string(TronIdentity.usdt),"asset_name":.string(legacy),"amount":.number("9007199254740993")])])])])])])
        let receipt=TronJSON.object(["id":.string(hash),"blockNumber":.number("100"),"blockTimeStamp":.number("123000")])
        let pending=try TronDecoding.transaction(hash:hash,body:body,receipt:receipt,solidHeight:99,legacyAssetIDs:[legacy:"1002000"])
        XCTAssertFalse(pending.confirmed);XCTAssertEqual(pending.events.first?.reference,"1002000");XCTAssertEqual(pending.events.first?.amount,"9007199254740993")
        let solid=try TronDecoding.transaction(hash:hash,body:body,receipt:receipt,solidHeight:100,legacyAssetIDs:[legacy:"1002000"])
        XCTAssertTrue(solid.confirmed)
        XCTAssertThrowsError(try TronDecoding.transaction(hash:hash,body:body,receipt:receipt))
    }
    func testLivePricesAgainstTronscanAndIndependentNativeQuote() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIVE_TRON_PRICES"] == "1" else { throw XCTSkip("Opt-in keyless market comparison") }
        let markets=TronMarkets(), transport=AnkrHTTPTransport()
        async let nativeQuote=markets.nativePrice()
        let catalog=try TronMarkets.decodeCatalog(await markets.catalog())
        let native=try await nativeQuote, trx=try XCTUnwrap(Double(native.usd))
        let (bytes,status)=try await transport.send(URLRequest(url:URL(string:"https://apilist.tronscanapi.com/api/account?address="+Self.owner)!))
        XCTAssertEqual(status,200)
        let scan=try JSONDecoder().decode(TronJSON.self,from:bytes)
        let rows=try XCTUnwrap(scan["tokens"].array)
        var scanQuotes:[String:Double]=[:]
        for row in rows {
            guard let ref=row["tokenId"].string,catalog[ref] != nil,let text=row["tokenPriceInTrx"].text,let price=Double(text),price>0 else { continue }
            scanQuotes[ref]=price*trx
        }
        let quotes=try await markets.prices(mints:scanQuotes.keys.sorted())
        XCTAssertGreaterThanOrEqual(quotes.count,4)
        for quote in quotes {
            let own=try XCTUnwrap(Double(quote.usd)), explorer=try XCTUnwrap(scanQuotes[quote.mint])
            let difference=abs(own/explorer-1)
            XCTAssertLessThan(difference,0.10,"Independent live venues differ by more than 10%: \(quote.mint)")
            print("TRON price comparison \(catalog[quote.mint]!.symbol): app USD \(own), Tronscan USD \(explorer), difference \(difference*100)%")
        }
        try await Task.sleep(for:.milliseconds(2200))
        let (g,gs)=try await transport.send(URLRequest(url:URL(string:"https://api.coingecko.com/api/v3/simple/price?ids=tron&vs_currencies=usd")!))
        XCTAssertEqual(gs,200)
        let independent=try XCTUnwrap(Double(JSONDecoder().decode(TronJSON.self,from:g)["tron"]["usd"].text ?? ""))
        XCTAssertLessThan(abs(trx/independent-1),0.05)
        print("TRON native price comparison: Coinbase USD \(trx), CoinGecko USD \(independent)")
    }
    func testBatchIDsReorderedMissingAndRPCError() async throws {
        let ok = try TronClient(apiKey:"fixture",transport:TronStub(response:Data("""
        [{"jsonrpc":"2.0","id":1,"result":"second"},{"jsonrpc":"2.0","id":0,"result":"first"}]
        """.utf8)))
        let result = try await ok.batch([("a",[]),("b",[])])
        XCTAssertEqual(result,[.string("first"),.string("second")])
        let bad = try TronClient(apiKey:"fixture",transport:TronStub(response:Data("""
        [{"jsonrpc":"2.0","id":0,"error":{"code":-32000}}]
        """.utf8)))
        do { _ = try await bad.batch([("a",[])]); XCTFail() } catch { XCTAssertEqual(error as? TronError,.rpc(-32000)) }
    }
    func testIndexFailureStillReturnsNativeStateWithoutClaimingCompleteDiscovery() async throws {
        let client = try TronClient(apiKey:"fixture",transport:TronIndexFailure(owner:Self.owner))
        let inventory = try await client.inventory(owner:Self.owner)
        XCTAssertFalse(inventory.discoveryComplete)
        XCTAssertEqual(inventory.holdings.count,1)
        XCTAssertEqual(inventory.holdings[0].amount,"9007199254740993")
    }
    func testLiveThreePublicWalletsAgainstTronscanAndTronGrid() async throws {
        guard let key=ProcessInfo.processInfo.environment["OATH_LIVE_TRON_COMPARE_KEY"],!key.isEmpty else { throw XCTSkip("Opt-in public explorer comparison") }
        let client=try TronClient(apiKey:key), markets=TronMarkets(), transport=AnkrHTTPTransport()
        let directory=try TronMarkets.decodeCatalog(await markets.catalog())
        var total=0, compared=0, priced=0
        for owner in [Self.owner,"TQguVRm3tDmZG7AeZ47Mk6qi6GTF1ZDqkZ","TWd4WrZ9wn84f5x1hZhL4DHvk738ns5jwb"] {
            // These wallets can move funds while sampled. Retry a complete pair
            // of snapshots; do not silently drop a mismatching amount.
            var matched=false
            for _ in 0..<3 {
                let inventory=try await client.inventory(owner:owner)
                XCTAssertTrue(inventory.discoveryComplete)
                XCTAssertTrue(inventory.failedReferences.isEmpty,"Unresolved public contracts: \(inventory.failedReferences)")
                let amounts=Dictionary(uniqueKeysWithValues:inventory.holdings.map{($0.token.reference,$0.amount)})
                let (bytes,status)=try await transport.send(URLRequest(url:URL(string:"https://apilist.tronscanapi.com/api/account?address="+owner)!))
                XCTAssertEqual(status,200)
                let scan=try JSONDecoder().decode(TronJSON.self,from:bytes)
                XCTAssertEqual(scan["address"].string,owner)
                let rows=try XCTUnwrap(scan["tokens"].array)
                var mismatch=0, differences: Set<String> = []
                let excluded = Set(inventory.excludedNFTs)
                for row in rows {
                    let raw=try XCTUnwrap(row["tokenId"].string), ref=raw == "_" ? "native" : raw
                    if excluded.contains(ref) { continue } // ERC165-confirmed NFT, not fungible currency.
                    if !TronIdentity.isToken(ref) && ref != "native" { continue }
                    let amount=try TronIdentity.quantity(row["balance"])
                    if amounts[ref] != amount { differences.insert(ref) }
                }
                try await Task.sleep(for:.milliseconds(1200))
                let (g,gs)=try await transport.send(URLRequest(url:URL(string:"https://api.trongrid.io/v1/accounts/"+owner)!))
                XCTAssertEqual(gs,200)
                let grid=try XCTUnwrap(JSONDecoder().decode(TronJSON.self,from:g)["data"].array?.first)
                var expected:[String:String]=["native":try TronIdentity.quantity(grid["balance"])]
                for token in grid["trc20"].array ?? [] { for (ref,v) in token.fields ?? [:] where !excluded.contains(ref) { expected[ref]=try TronIdentity.quantity(v) } }
                for token in grid["assetV2"].array ?? [] { expected[token["key"].string!]=try TronIdentity.quantity(token["value"]) }
                for ref in Set(expected.keys).union(amounts.keys) where expected[ref] != amounts[ref] { differences.insert(ref) }
                // Indexed balances of rebasing/nonstandard spam contracts can
                // be stale. Check each discrepancy against an independent live
                // contract execution; never replace ANKR's value with an index.
                for ref in differences.sorted() {
                    guard TronIdentity.isAddress(ref) else { mismatch += 1; continue }
                    try await Task.sleep(for:.milliseconds(1200))
                    let ownerHex=String(try TronIdentity.callAddress(owner).dropFirst(2))
                    let body=TronJSON.object(["owner_address":.string(owner),"contract_address":.string(ref),"function_selector":.string("balanceOf(address)"),"parameter":.string(String(repeating:"0",count:24)+ownerHex),"visible":.bool(true)])
                    var request=URLRequest(url:URL(string:"https://api.trongrid.io/wallet/triggerconstantcontract")!)
                    request.httpMethod="POST";request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.httpBody=try JSONEncoder().encode(body)
                    let (bytes,status)=try await transport.send(request);XCTAssertEqual(status,200)
                    let result=try JSONDecoder().decode(TronJSON.self,from:bytes)
                    XCTAssertEqual(result["result"]["result"],.bool(true))
                    XCTAssertTrue(result["result"]["message"].isNull)
                    let word=try XCTUnwrap(result["constant_result"].array?.first?.string)
                    let independent=try TronIdentity.uint256(word)
                    if independent != amounts[ref] { mismatch += 1 }
                    else { print("TRON independent RPC verified index discrepancy \(ref)") }
                }
                if mismatch == 0 {
                    matched=true;total += amounts.count;compared += rows.count
                    let refs=amounts.keys.filter{ $0 != "native" && amounts[$0] != "0" && directory[$0] != nil }.sorted()
                    var quotes:[TronPrice]=[]
                    for i in stride(from:0,to:refs.count,by:30) { quotes += try await markets.prices(mints:Array(refs[i..<min(i+30,refs.count)])) }
                    priced += quotes.count
                    XCTAssertEqual(Set(quotes.map(\.mint)),Set(refs),"Missing price for listed tokens")
                    print("TRON explorer match \(owner): \(amounts.count) exact balances; \(rows.count) Tronscan rows; \(differences.count) differences checked on independent RPC; \(quotes.count) priced tokens")
                    break
                }
                try await Task.sleep(for:.seconds(2))
            }
            XCTAssertTrue(matched,"Public wallet changed or provider disagreed after three fresh comparisons: \(owner)")
        }
        print("TRON independent totals: \(total) exact balances, \(compared) explorer rows, \(priced) priced holdings")
    }
    func testLiveInventoryPricesAndThreeHistoryStreams() async throws {
        guard let key=ProcessInfo.processInfo.environment["OATH_LIVE_TRON_KEY"],!key.isEmpty else { throw XCTSkip("Opt-in public mainnet read-only test") }
        let client=try TronClient(apiKey:key,transport:TronLiveTransport()), markets=TronMarkets()
        async let inventory=client.inventory(owner:Self.owner)
        async let directory=markets.catalog()
        async let price=markets.nativePrice()
        let values=try await inventory
        let catalog=try TronMarkets.decodeCatalog(await directory)
        XCTAssertEqual(values.holdings.first(where:{$0.token.reference=="native"})?.amount,"3577033")
        XCTAssertTrue(values.holdings.count > 50)
        print("TRON inventory: \(values.holdings.count) successful holdings; \(values.failedReferences.count) failed references")
        if !values.failedReferences.isEmpty { print("Failed public contracts: \(values.failedReferences)") }
        let native=try await price; XCTAssertGreaterThan(Decimal(string:native.usd)!,0)
        let refs=values.holdings.filter{$0.amount != "0" && catalog[$0.token.reference] != nil && TronIdentity.isAddress($0.token.reference)}.map{$0.token.reference}
        let quotes=try await markets.prices(mints:refs)
        XCTAssertNotNil(quotes.first{$0.mint==TronIdentity.usdt})
        print("TRON priced listed contracts: \(quotes.count) / \(refs.count); TRX USD \(native.usd)")
        let end=Int64(Date().timeIntervalSince1970*1000)
        for stream in TronStream.allCases {
            let page=try await client.history(owner:Self.owner,stream:stream,start:0,end:end,limit:5)
            XCTAssertFalse(page.hashes.isEmpty)
            if let cursor=page.cursor { let second=try await client.history(owner:Self.owner,stream:stream,start:0,end:end,cursor:cursor,limit:5); XCTAssertNotEqual(second.hashes,page.hashes) }
            let tx=try await client.transaction(page.hashes[0]); XCTAssertEqual(tx.hash,page.hashes[0])
            print("TRON \(stream): first+next pages and ANKR receipt verified")
        }
    }
}
private struct TronStub: AnkrTransport { let response: Data; func send(_ request: URLRequest) async throws -> (Data,Int) { (response,200) } }

private struct TronLiveTransport: AnkrTransport {
    let base = AnkrHTTPTransport()
    func send(_ request: URLRequest) async throws -> (Data,Int) {
        let result = try await base.send(request)
        if result.1 != 200 { print("TRON provider status \(request.url?.host ?? "unknown"): \(result.1)"); if request.url?.host == "api.trongrid.io" { print(String(data: result.0, encoding: .utf8)?.prefix(500) ?? "") } }
        return result
    }
}

private struct TronIndexFailure: AnkrTransport {
    let owner:String
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        let value:TronJSON
        if request.url?.host == "api.trongrid.io" { value = .object(["success":.bool(false)]) }
        else if request.url?.lastPathComponent == "getaccount" { value = .object(["address":.string(owner),"balance":.number("9007199254740993")]) }
        else { value = .array([.object(["jsonrpc":.string("2.0"),"id":.number("0"),"result":.string("0x2b6653dc")])]) }
        return (try JSONEncoder().encode(value),200)
    }
}

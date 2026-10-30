import Foundation
import XCTest
@testable import OathAnkr

final class TonTests: XCTestCase, @unchecked Sendable {
    static let owner = "0:23fa979918f1fe702db9100bf843e87c7015eccd39a4721e9b6bac170bc04ce3"
    static let wallet = "0:2626cf30b702bdded845efc883efa45029ff59defdacc4ce7b8b0a5966d75002"
    func fixture(_ name: String) throws -> Data { try Data(contentsOf:Bundle.module.url(forResource:name,withExtension:"json",subdirectory:"Fixtures/Ton")!) }
    func json(_ name: String) throws -> TonJSON { try JSONDecoder().decode(TonJSON.self,from:fixture(name)) }
    func testAddressAliasesCRCNetworkAndExactAmounts() throws {
        let bounceable = try TonIdentity.friendly(Self.owner), plain = try TonIdentity.friendly(Self.owner,bounceable:false)
        XCTAssertNotEqual(bounceable,plain)
        for address in [bounceable,plain,Self.owner.uppercased()] { XCTAssertEqual(try TonIdentity.raw(address),Self.owner) }
        XCTAssertEqual(try TonIdentity.raw("EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs"),TonIdentity.usdt)
        XCTAssertThrowsError(try TonIdentity.raw(String(bounceable.dropLast())+"A"))
        var testnet = try XCTUnwrap(TonIdentity.base64(bounceable)); testnet[0] |= 0x80
        testnet = Data(testnet.prefix(34)); testnet += TonIdentity.crc16(testnet)
        XCTAssertThrowsError(try TonIdentity.raw(testnet.base64EncodedString()))
        let value = try JSONDecoder().decode(TonJSON.self,from:Data("59570010157331145".utf8))
        XCTAssertEqual(try TonIdentity.amount(value),"59570010157331145")
        XCTAssertThrowsError(try TonIdentity.amount(.number("-1")))
        XCTAssertThrowsError(try TonIdentity.amount(.number("1.2")))
        XCTAssertEqual(try TonIdentity.walletAddress(json("walletBinding")["result"]),Self.wallet)
        XCTAssertEqual(try TonIdentity.base64(TonIdentity.addressSlice(Self.owner))?.count,47)
    }
    func testNativeHistoryIncludesCreditsOnFailedComputeAndRejectsWrongAccount() throws {
        let value = try json("transactions")
        let page = try TonDecoding.history(value,owner:Self.owner,stream:.native,before:nil,limit:5)
        XCTAssertEqual(page.transactions.count,5)
        XCTAssertTrue(page.transactions[0].failed)
        XCTAssertEqual(page.transactions[0].events.first?.amount,"1")
        XCTAssertEqual(page.transactions[0].fee,"58")
        XCTAssertNotNil(page.next)
        XCTAssertThrowsError(try TonDecoding.history(value,owner:TonIdentity.usdt,stream:.native,before:nil,limit:5))
        XCTAssertThrowsError(try TonDecoding.history(value,owner:Self.owner,stream:.native,before:1,limit:5))
    }
    func testJettonHistoryPricesAndStableEventIdentity() throws {
        let value = try json("operations")
        let page = try TonDecoding.history(value,owner:Self.owner,stream:.jettons,before:nil,limit:1000)
        XCTAssertFalse(page.transactions.isEmpty)
        let first = page.transactions[0]
        let subset:TonJSON = .object(["operations":.array([value["operations"].array![0]])])
        let replay = try TonDecoding.history(subset,owner:Self.owner,stream:.jettons,before:nil,limit:1000)
        XCTAssertEqual(first.events,replay.transactions[0].events)
        XCTAssertTrue(first.events[0].token.verified)
        let quotes = try TonMarkets.decodePrices(fixture("dex"),references:[TonIdentity.usdt])
        XCTAssertEqual(quotes.count,1); XCTAssertEqual(quotes[0].reference,TonIdentity.usdt)
        XCTAssertNil(TonMarkets.positive(.number("0")))
        XCTAssertTrue(try TonMarkets.decodePrices(fixture("dex"),references:[Self.owner]).isEmpty)
    }
    func testCancelledTokenReadNeverBecomesPartialInventory() async throws {
        let client = TonClient(testTransport: TonFixtureTransport(inventory: try json("inventory"), binding: try json("walletBinding")["result"], cancelHolding: true))
        do { _ = try await client.inventory(owner: Self.owner); XCTFail("Cancelled token work must cancel inventory") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testDiscoveryCauseIsEphemeralAndOldInventoriesStillDecode() async throws {
        let client = TonClient(testTransport: TonFixtureTransport(inventory: try json("inventory"), binding: try json("walletBinding")["result"], indexFailure: true))
        let value = try await client.inventory(owner: Self.owner)
        XCTAssertEqual(value.discoveryError, .http(400))
        let bytes = try JSONEncoder().encode(value)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(fields["discoveryError"])
        let restored = try JSONDecoder().decode(TonInventory.self, from: bytes)
        XCTAssertNil(restored.discoveryError)
        XCTAssertFalse(restored.discoveryComplete)
        XCTAssertEqual(restored.holdings.count, value.holdings.count)
    }
    func testInventoryValidatesBothWalletBindingsAndPreservesPartialFailures() async throws {
        let root = try json("inventory"), binding = try json("walletBinding")["result"]
        let stub = TonFixtureTransport(inventory:root,binding:binding)
        let client = TonClient(testTransport:stub)
        let value = try await client.inventory(owner:Self.owner)
        XCTAssertTrue(value.discoveryComplete);XCTAssertTrue(value.failedReferences.isEmpty)
        XCTAssertEqual(value.holdings.first{$0.token.reference==TonIdentity.usdt}?.amount,"879187990649145")
        XCTAssertEqual(value.prices.count,1)
        let bad = TonClient(testTransport:TonFixtureTransport(inventory:root,binding:binding,wrongOwner:true))
        let partial = try await bad.inventory(owner:Self.owner)
        XCTAssertEqual(partial.failedReferences,[TonIdentity.usdt]);XCTAssertEqual(partial.holdings.count,1)
        let unavailable = TonClient(testTransport:TonFixtureTransport(inventory:root,binding:binding,indexFailure:true))
        let missing = try await unavailable.inventory(owner:Self.owner)
        XCTAssertFalse(missing.discoveryComplete);XCTAssertEqual(missing.holdings.count,1)
    }
    func testJettonPageOverlapKeepsEqualLogicalTimesAndMintBurn() throws {
        var row = try XCTUnwrap(json("operations")["operations"].array?.first?.fields)
        row["lt"] = .number("100")
        let first:TonJSON = .object(["operations":.array([.object(row)]),"next_from":.number("100")])
        let boundary = try TonDecoding.history(first,owner:Self.owner,stream:.jettons,before:nil,limit:1)
        XCTAssertEqual(boundary.next,101)
        var sibling = row; sibling["transaction_hash"] = .string(String(repeating:"c",count:64))
        var older = row; older["transaction_hash"] = .string(String(repeating:"d",count:64)); older["lt"] = .number("90")
        let following:TonJSON = .object(["operations":.array([.object(row),.object(sibling),.object(older)]),"next_from":.number("90")])
        let page = try TonDecoding.history(following,owner:Self.owner,stream:.jettons,before:101,limit:3)
        XCTAssertEqual(page.transactions.count,3);XCTAssertEqual(page.next,91)
        XCTAssertEqual(page.transactions[0].events,boundary.transactions[0].events)
        XCTAssertThrowsError(try TonDecoding.history(first,owner:Self.owner,stream:.jettons,before:101,limit:1))
        row["operation"] = .string("mint");row["source"] = .null
        var mint = try TonDecoding.history(.object(["operations":.array([.object(row)])]),owner:Self.owner,stream:.jettons,before:nil,limit:100)
        XCTAssertEqual(mint.transactions[0].events[0].from,"")
        row["operation"] = .string("burn");row["source"] = row["destination"];row["destination"] = .null
        mint = try TonDecoding.history(.object(["operations":.array([.object(row)])]),owner:Self.owner,stream:.jettons,before:nil,limit:100)
        XCTAssertEqual(mint.transactions[0].events[0].to,"")
    }
    func testDiscoveryPaginatesAndNeverTreatsFailedPageAsEmpty() async throws {
        let rows:[TonJSON] = (1...1000).map { .object(["jetton":.object(["address":.string("0:"+String(format:"%064x",$0))])]) }
        for failure in [false,true] {
            let client=TonClient(testTransport:TonPagedFixture(rows:rows,failure:failure))
            let (tokens,pages,complete,cause)=try await client.discovery(Self.owner)
            XCTAssertEqual(tokens.count,1000);XCTAssertEqual(pages.count,failure ? 1 : 2);XCTAssertEqual(complete,!failure)
            XCTAssertEqual(cause, failure ? .http(400) : nil)
        }
    }
    func testPricesRejectMalformedTextAndWrongChainEvenForMatchingTicker() throws {
        XCTAssertNil(TonMarkets.positive(.string("1.5garbage")))
        XCTAssertNil(TonMarkets.positive(.string("NaN")))
        XCTAssertNil(TonMarkets.positive(.string("-5")))
        XCTAssertEqual(TonMarkets.positive(.string("1e-9")),"0.000000001")
        let pair:TonJSON = .object(["chainId":.string("ethereum"),"baseToken":.object(["address":.string(TonIdentity.usdt)]),"priceUsd":.string("999"),"liquidity":.object(["usd":.number("1000000")])])
        XCTAssertTrue(try TonMarkets.decodePrices(JSONEncoder().encode(TonJSON.array([pair])),references:[TonIdentity.usdt]).isEmpty)
    }
    func testLiveThreeFundedWalletsAgainstToncenterAndTonAPI() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_LIVE_TON_KEY"], !key.isEmpty else { throw XCTSkip("Opt-in public TON comparison") }
        let client = try TonClient(apiKey:key), markets = TonMarkets(), transport = AnkrHTTPTransport()
        let owners = [Self.owner,"0:f8b8635d0786b77f9da660e65fd31d670a675dd4302facba692f46b571eb5360","0:8afbcb163358eb20be1ae9b610a2938038d84a1087e7f49cccbf8046f59c859f"]
        var holdingsCount = 0, pricesCount = 0
        for owner in owners {
            let value = try await client.inventory(owner:owner)
            XCTAssertTrue(value.discoveryComplete);XCTAssertTrue(value.failedReferences.isEmpty,"Failed token references: \(value.failedReferences)")
            let amounts = Dictionary(uniqueKeysWithValues:value.holdings.map{($0.token.reference,$0.amount)})
            var request = URLRequest(url:URL(string:"https://toncenter.com/api/v3/jetton/wallets?owner_address="+owner+"&limit=1000&offset=0")!)
            request.setValue("OathWallet/1.0",forHTTPHeaderField:"User-Agent")
            let (data,status) = try await transport.send(request);XCTAssertEqual(status,200)
            let independent = try JSONDecoder().decode(TonJSON.self,from:data)
            let wallets = try XCTUnwrap(independent["jetton_wallets"].array);XCTAssertLessThan(wallets.count,1000)
            var expected: [String:String] = [:]
            for wallet in wallets {
                XCTAssertEqual(try TonIdentity.raw(wallet["owner"].string!),owner)
                expected[try TonIdentity.raw(wallet["jetton"].string!)] = try TonIdentity.amount(wallet["balance"])
            }
            // Indexers may retain zero-balance wallets differently. Compare
            // every nonzero holding in either inventory, including hidden spam.
            let refs = Set(expected.filter{$0.value != "0"}.keys).union(amounts.filter{$0.key != "native" && $0.value != "0"}.keys)
            for ref in refs { XCTAssertEqual(amounts[ref] ?? "0",expected[ref] ?? "0","Balance disagrees for \(ref)") }
            let account = try await client.indexed("accounts/"+owner)
            XCTAssertEqual(try TonIdentity.amount(account["balance"]),amounts["native"])
            let prices = value.prices.filter{ quote in value.holdings.contains{$0.token.reference==quote.reference && $0.token.verified} }
            XCTAssertFalse(prices.isEmpty)
            holdingsCount += amounts.count;pricesCount += prices.count
            print("TON live comparison \(owner): \(amounts.count) ANKR balances, \(wallets.count) independent Jetton wallets, \(prices.count) verified-token USD quotes")
            for stream in TonStream.allCases {
                let page = try await client.history(owner:owner,stream:stream,limit:5)
                XCTAssertFalse(page.transactions.isEmpty)
                if owner == Self.owner {
                    let path = stream == .native ? "transactions?account=" : "jetton/transfers?owner_address="
                    var request = URLRequest(url:URL(string:"https://toncenter.com/api/v3/"+path+owner+"&limit=5&sort=desc")!)
                    request.setValue("OathWallet/1.0",forHTTPHeaderField:"User-Agent")
                    let (data,status) = try await transport.send(request);XCTAssertEqual(status,200)
                    let center = try JSONDecoder().decode(TonJSON.self,from:data)
                    if stream == .native {
                        let rows = try XCTUnwrap(center["transactions"].array)
                        let hashes = try Set(rows.map{try TonIdentity.hash($0["hash"].string!)})
                        XCTAssertEqual(hashes,Set(page.transactions.map(\.hash)))
                        for row in rows {
                            let hash = try TonIdentity.hash(row["hash"].string!)
                            XCTAssertEqual(page.transactions.first{$0.hash==hash}?.fee,try TonIdentity.amount(row["total_fees"]))
                        }
                    } else {
                        // Toncenter indexes the sending contract transaction;
                        // TonAPI may index its receiving leg. Match the common
                        // trace, master, owners and amount rather than confusing
                        // two different transaction hashes in the same transfer.
                        let rows = try XCTUnwrap(center["jetton_transfers"].array)
                        let expected = try Set(rows.map { row in
                            try [TonIdentity.hash(row["trace_id"].string!),TonIdentity.raw(row["jetton_master"].string!),TonIdentity.raw(row["source"].string!),TonIdentity.raw(row["destination"].string!),TonIdentity.amount(row["amount"])].joined(separator:"|")
                        })
                        let operations = try XCTUnwrap(JSONDecoder().decode(TonJSON.self,from:page.raw)["operations"].array)
                        let actual = try Set(operations.map { row in
                            try [TonIdentity.hash(row["trace_id"].string!),TonIdentity.raw(row["jetton"]["address"].string!),TonIdentity.raw(row["source"]["address"].string!),TonIdentity.raw(row["destination"]["address"].string!),TonIdentity.amount(row["amount"])].joined(separator:"|")
                        })
                        XCTAssertEqual(actual,expected)
                    }
                    print("TON independent history matched: \(stream.rawValue), \(page.transactions.count) records")
                }
                if let next = page.next {
                    let second = try await client.history(owner:owner,stream:stream,before:next,limit:5)
                    XCTAssertTrue(second.transactions.allSatisfy{$0.lt < next})
                }
            }
        }
        let coinbase = try await markets.nativePrice()
        let rate = try await client.prices(references:["native",TonIdentity.usdt])
        let ton = try XCTUnwrap(rate.first{$0.reference=="native"}), usdt = try XCTUnwrap(rate.first{$0.reference==TonIdentity.usdt})
        let dexPrices = try await markets.prices(references:[TonIdentity.usdt])
        let dex = try XCTUnwrap(dexPrices.first)
        XCTAssertLessThan(abs(Double(coinbase.usd)!/Double(ton.usd)!-1),0.05)
        XCTAssertLessThan(abs(Double(usdt.usd)!/Double(dex.usd)!-1),0.05)
        let otherTokens = ["0:afc49cb8786f21c87045b19ede78fc6b46c51048513f8e9a6d44060199c1bf0c","0:2f956143c461769579baef2e32cc2d7bc18283f40d20bb03e432cd603ac33ffc"]
        let tokenRates = try await client.prices(references:otherTokens)
        let tokenDex = try await markets.prices(references:otherTokens)
        XCTAssertEqual(tokenRates.count,2);XCTAssertEqual(tokenDex.count,2)
        for price in tokenRates {
            let other = try XCTUnwrap(tokenDex.first{$0.reference==price.reference})
            XCTAssertLessThan(abs(Double(price.usd)!/Double(other.usd)!-1),0.05)
            print("TON token contract price comparison \(price.reference): TonAPI USD \(price.usd), DEX USD \(other.usd)")
        }
        print("TON totals: \(holdingsCount) exact balances; \(pricesCount) verified-token prices. Native Coinbase/TonAPI USD \(coinbase.usd)/\(ton.usd); USDT TonAPI/DEX USD \(usdt.usd)/\(dex.usd)")
    }
}
private struct TonFixtureTransport: AnkrTransport {
    let inventory:TonJSON
    let binding:TonJSON
    var wrongOwner = false
    var indexFailure = false
    var cancelHolding = false
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        let value:TonJSON
        if request.url!.host == "tonapi.io" { if indexFailure { return (Data(),400) }; value=inventory }
        else {
            let call=try JSONDecoder().decode(TonJSON.self,from:request.httpBody!), method=call["method"].string
            let result:TonJSON
            switch method {
            case "getMasterchainInfo":result = .object(["init":.object(["root_hash":.string(TonIdentity.genesis)])])
            case "getAddressInformation": result = .object(["state":.string("active"),"balance":.string("6684406248")])
            case "runGetMethod": result = binding
            case "getTokenData":
                if cancelHolding { throw CancellationError() }
                result = .object(["contract_type":.string("jetton_wallet"),"owner":.string(wrongOwner ? TonIdentity.usdt : TonTests.owner),"jetton":.string(TonIdentity.usdt),"balance":.number("879187990649145")])
            default:throw TonError.malformed
            }
            value = .object(["jsonrpc":.string("2.0"),"id":.string("1"),"result":result])
        }
        return (try JSONEncoder().encode(value),200)
    }
}

private struct TonPagedFixture: AnkrTransport {
    let rows:[TonJSON]
    let failure:Bool
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        let offset = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!.first{$0.name=="offset"}!.value!
        if offset != "0",failure{return (Data(),400)}
        return (try JSONEncoder().encode(TonJSON.object(["balances":.array(offset=="0" ? rows : [])])),200)
    }
}

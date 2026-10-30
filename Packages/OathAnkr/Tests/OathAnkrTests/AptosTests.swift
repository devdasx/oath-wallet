import Foundation
import XCTest
@testable import OathAnkr

final class AptosTests:XCTestCase,@unchecked Sendable {
    static let owner=try! AptosIdentity.address("0x1234")
    static let token=try! AptosIdentity.address("0xabcd")
    func fixture(_ name:String) throws -> Data {try Data(contentsOf:Bundle.module.url(forResource:name,withExtension:"json",subdirectory:"Fixtures/Aptos")!)}
    func testLiveFundedAccountsNodeReceiptsAndPrices() async throws {
        guard let key=ProcessInfo.processInfo.environment["OATH_LIVE_APTOS_KEY"] else {throw XCTSkip("Opt-in public-network test")}
        let client=try AptosClient(apiKey:key,indexerKey:ProcessInfo.processInfo.environment["OATH_LIVE_APTOS_INDEXER_KEY"])
        let markets=AptosMarkets(),catalog=try await markets.catalog()
        let owners=ProcessInfo.processInfo.environment["OATH_LIVE_APTOS_OWNERS"]?.split(separator:",").map(String.init) ?? [
            "0x041972b6755d06cc9129ab6b6a772aaca1061c8585ef3c15bddbc144bd05a63c"
        ]
        for owner in owners {
            let inventory=try await client.inventory(owner:owner)
            XCTAssertTrue(inventory.discoveryComplete);XCTAssertTrue(inventory.failedReferences.isEmpty)
            XCTAssertGreaterThan(inventory.holdings.count,1)
            // Independent official full node at the same ledger version.
            var url=URLComponents(string:"https://api.mainnet.aptoslabs.com/v1/view")!
            url.queryItems=[.init(name:"ledger_version",value:String(inventory.ledgerVersion))]
            var request=URLRequest(url:url.url!);request.httpMethod="POST"
            request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            let pages=try JSONDecoder().decode(AptosJSON.self,from:inventory.raw).array ?? []
            let rows=pages.flatMap{$0["current_fungible_asset_balances"].array ?? []}
            for holding in inventory.holdings {
                let ref=holding.token.reference=="native" ? AptosIdentity.coin:holding.token.reference
                let isCoin=ref.contains("::")
                request.httpBody=try JSONEncoder().encode(AptosJSON.object([
                    "function":.string(isCoin ? "0x1::coin::balance":"0x1::primary_fungible_store::balance"),
                    "type_arguments":.array([.string(isCoin ? ref:"0x1::fungible_asset::Metadata")]),
                    "arguments":.array((isCoin ? [owner]:[owner,ref]).map{.string($0)})]))
                let (tokenData,tokenStatus)=try await AnkrHTTPTransport().send(request)
                XCTAssertEqual(tokenStatus,200)
                var expected=try AptosIdentity.amount(JSONDecoder().decode(AptosJSON.self,from:tokenData).array!.first!)
                for row in rows where row["is_primary"] == .bool(false) && !row["amount_v2"].isNull {
                    let type=try AptosIdentity.reference(row["asset_type"].string!)
                    guard (inventory.pairedReferences?[type] ?? type)==holding.token.reference else {continue}
                    request.httpBody=try JSONEncoder().encode(AptosJSON.object([
                        "function":.string("0x1::dispatchable_fungible_asset::derived_balance"),
                        "type_arguments":.array([.string("0x1::fungible_asset::FungibleStore")]),
                        "arguments":.array([row["storage_id"]])]))
                    let (data,status)=try await AnkrHTTPTransport().send(request);XCTAssertEqual(status,200)
                    expected=AptosIdentity.add(expected,try AptosIdentity.amount(JSONDecoder().decode(AptosJSON.self,from:data).array!.first!))
                }
                XCTAssertEqual(expected,holding.amount)
            }
            let page=try await client.history(owner:owner,limit:5)
            XCTAssertFalse(page.transactions.isEmpty)
            if let next=page.next {
                let older=try await client.history(owner:owner,before:next,limit:5)
                XCTAssertTrue(older.transactions.allSatisfy{$0.version<next})
            }
            let references=Array(Set(inventory.holdings.map{catalog.canonical($0.token.reference)}))
            var quotes:[AptosPrice]=[]
            for start in stride(from:0,to:references.count,by:30) {
                quotes += try await markets.prices(references:Array(references[start..<min(start+30,references.count)]))
            }
            XCTAssertFalse(quotes.isEmpty)
            for quote in quotes {XCTAssertNotNil(Decimal(string:quote.usd));XCTAssertTrue(references.contains(quote.reference))}
            print("APTOS_LIVE holders=1 holdings=\(inventory.holdings.count) receipts=\(page.transactions.count) quotes=\(quotes.count) amountsMatched=\(inventory.holdings.count)")
            if let folder=ProcessInfo.processInfo.environment["OATH_LIVE_APTOS_OUTPUT"] {
                let root=URL(fileURLWithPath:folder)
                try JSONEncoder().encode(inventory).write(to:root.appendingPathComponent(owner+"-inventory.json"))
                try JSONEncoder().encode(page.transactions).write(to:root.appendingPathComponent(owner+"-history.json"))
            }
        }
        let native=try await markets.nativePrice();XCTAssertEqual(native.reference,"native")
        let panora=try await markets.prices(references:["native"])
        XCTAssertEqual(panora.count,1)
        let primary=Decimal(string:native.usd)!,secondary=Decimal(string:panora[0].usd)!
        XCTAssertLessThan(abs(primary-secondary)/primary,Decimal(string:"0.05")!)
        let usdc="0xbae207659db88bea0cbead6da0ed00aac12edcdda169e591cd41c94180b46f3b"
        let dex=try await markets.dexPrices(references:[usdc]);XCTAssertEqual(dex.count,1)
        XCTAssertGreaterThan(Decimal(string:dex[0].usd)!,Decimal(string:"0.9")!)
        XCTAssertLessThan(Decimal(string:dex[0].usd)!,Decimal(string:"1.1")!)
    }
    func testCapturedMainnetNativeAndTokenReceipts() throws {
        let raw=try JSONDecoder().decode(AptosJSON.self,from:fixture("live-history")).array!
        var references=Set<String>(),directions=Set<String>()
        for pair in raw {
            let row=pair["index"],owner=row["account_address"].string!
            let tx=try AptosDecoding.transaction(row:row,detail:pair["receipt"],owner:owner)
            XCTAssertGreaterThan(tx.version,0);XCTAssertFalse(tx.events.isEmpty)
            for event in tx.events {references.insert(event.token.reference);directions.insert(event.direction)}
        }
        XCTAssertTrue(references.contains("native"));XCTAssertGreaterThan(references.count,1)
        XCTAssertTrue(directions.contains("incoming"));XCTAssertTrue(directions.contains("outgoing"))
    }
    func testIdentityAndExactAmounts() throws {
        XCTAssertEqual(try AptosIdentity.reference("0x0001::aptos_coin::AptosCoin"),"native")
        XCTAssertEqual(try AptosIdentity.reference("0xA"),"native")
        XCTAssertEqual(try AptosIdentity.reference("0xAB::m::C<0x0001::a::B>"),"0xab::m::C<0x1::a::B>")
        XCTAssertThrowsError(try AptosIdentity.address("0xno"))
        XCTAssertThrowsError(try AptosIdentity.reference("0x1::coin\""))
        let n="340282366920938463463374607431768211455"
        XCTAssertEqual(try AptosIdentity.amount(.string(n)),n)
        XCTAssertEqual(AptosIdentity.add(n,"1"),"340282366920938463463374607431768211456")
        for value in ["-1","1.1","nan","1e8",""] {XCTAssertThrowsError(try AptosIdentity.amount(.string(value)))}
    }
    func testHistoricalReceiptsGoDirectlyToArchiveWithoutProviderCredential() async throws {
        let transport=AptosArchiveTransport(receipt:try fixture("receipt"))
        let value=try await AptosClient(testTransport:transport).node("transactions/by_version/7575054398")
        XCTAssertEqual(value["version"].text,"7575054398")
        let urls=await transport.requests
        XCTAssertEqual(urls.map(\.host),["archive.mainnet.aptoslabs.com"])
        XCTAssertTrue(urls.allSatisfy{!$0.path.contains("fixture")})
    }
    func testInventoryPrimaryAndSecondaryStoresWithoutDoubleCounting() async throws {
        let transport=AptosFixtureTransport(),client=AptosClient(testTransport:transport)
        let value=try await client.inventory(owner:Self.owner)
        XCTAssertTrue(value.discoveryComplete);XCTAssertEqual(value.failedReferences,[])
        XCTAssertEqual(value.ledgerVersion,1000)
        XCTAssertEqual(value.holdings.first{$0.token.reference==Self.token}?.amount,"30")
        XCTAssertEqual(value.holdings.first{$0.token.reference=="native"}?.amount,"9007199254740993")
        let state=await transport.counts();XCTAssertLessThanOrEqual(state.1,4)
    }
    func testPairedCoinIncludesPrimaryFAOnlyOnce() async throws {
        let client=AptosClient(testTransport:AptosFixtureTransport(pairedCoin:true))
        let value=try await client.inventory(owner:Self.owner)
        XCTAssertEqual(value.holdings.count,2)
        XCTAssertEqual(value.holdings.first{$0.token.reference=="0xabc::coin::Example"}?.amount,"30")
        XCTAssertNil(value.holdings.first{$0.token.reference==Self.token})
        XCTAssertTrue(value.failedReferences.isEmpty)
    }
    func testCancelledDiscoveryOrTokenReadNeverReturnsPartialInventory() async throws {
        for stage in ["discovery", "holding"] {
            let client = AptosClient(testTransport: AptosFixtureTransport(cancelStage: stage))
            do { _ = try await client.inventory(owner: Self.owner); XCTFail("Cancelled work returned partial inventory at " + stage) }
            catch { XCTAssertTrue(error is CancellationError) }
        }
    }
    func testIndexFailurePreservesUnknownTokensAndWrongOwnerDoesNotLeak() async throws {
        let blocked=AptosClient(testTransport:AptosFixtureTransport(indexFailure:true))
        let native=try await blocked.inventory(owner:Self.owner)
        XCTAssertFalse(native.discoveryComplete);XCTAssertEqual(native.holdings.count,1)
        XCTAssertEqual(native.discoveryError, .http(429))
        let encoded = try JSONEncoder().encode(native)
        let restored = try JSONDecoder().decode(AptosInventory.self, from: encoded)
        XCTAssertNil(restored.discoveryError, "Do not persist a transient diagnostic error into saved inventory")
        XCTAssertEqual(restored.discoveryFailure, native.discoveryFailure)
        XCTAssertEqual(restored.holdings, native.holdings)
        XCTAssertFalse(restored.discoveryComplete)
        let bad=AptosClient(testTransport:AptosFixtureTransport(wrongOwner:true))
        let value=try await bad.inventory(owner:Self.owner)
        XCTAssertFalse(value.discoveryComplete)
        let badStore=AptosClient(testTransport:AptosFixtureTransport(wrongStore:true))
        let partial=try await badStore.inventory(owner:Self.owner)
        XCTAssertEqual(partial.failedReferences,[Self.token])
        XCTAssertNil(partial.holdings.first{$0.token.reference==Self.token})
    }
    func testRealReceiptFailureGasAndEventValidation() throws {
        var tx=try JSONDecoder().decode(AptosJSON.self,from:fixture("receipt"))
        let owner=try AptosIdentity.address(tx["sender"].string!)
        let event:AptosJSON = .object(["owner_address":.string(owner),"asset_type":.string(AptosIdentity.coin),"event_index":.number("0"),"type":.string("0x1::fungible_asset::Withdraw"),"is_gas_fee":.bool(false),"is_transaction_success":tx["success"],"amount":.string("12345678901234567890")])
        let row:AptosJSON = .object(["account_address":.string(owner),"transaction_version":tx["version"],"fungible_asset_activities":.array([event])])
        // Synthetic transfer atop a real receipt header exercises event/receipt matching.
        var receipt=tx.fields!;receipt["events"] = .array([.object(["type":event["type"],"data":.object(["amount":event["amount"]])])]);tx = .object(receipt)
        let result=try AptosDecoding.transaction(row:row,detail:tx,owner:owner)
        XCTAssertEqual(result.fee,"37200")
        XCTAssertEqual(result.events.first?.amount,"12345678901234567890")
        var genericEvent=event.fields!
        genericEvent["type"] = .string("0x1::coin::Deposit<0x1::aptos_coin::AptosCoin>")
        var genericRow=row.fields!;genericRow["fungible_asset_activities"] = .array([.object(genericEvent)])
        var genericReceipt=tx.fields!
        genericReceipt["events"] = .array([.object(["type":genericEvent["type"]!,"data":.object(["amount":event["amount"]])])])
        let generic=try AptosDecoding.transaction(row:.object(genericRow),detail:.object(genericReceipt),owner:owner)
        XCTAssertEqual(generic.events.first?.direction,"incoming")
        XCTAssertThrowsError(try AptosDecoding.transaction(row:row,detail:tx,owner:Self.owner))
        var failed=tx.fields!;failed["success"] = .bool(false)
        var f=event.fields!;f["is_transaction_success"] = .bool(false)
        var fr=row.fields!;fr["fungible_asset_activities"] = .array([.object(f)])
        let error=try AptosDecoding.transaction(row:.object(fr),detail:.object(failed),owner:owner)
        XCTAssertTrue(error.failed);XCTAssertEqual(error.events.count,1);XCTAssertEqual(error.events[0].amount,"0")
    }
    func testRealBatchedQuotesKeepUnpricedAssetsUnknown() throws {
        let data=try fixture("prices-many")
        let rows=try JSONDecoder().decode(AptosJSON.self,from:data).array!
        let references=Set(try rows.compactMap{$0["tokenAddress"].string ?? $0["faAddress"].string}.map{try AptosIdentity.reference($0)})
        let prices=try AptosMarkets.decodePrices(data,references:references)
        XCTAssertEqual(rows.count,30);XCTAssertEqual(prices.count,26)
        XCTAssertTrue(prices.allSatisfy{references.contains($0.reference) && Decimal(string:$0.usd)!>0})
    }
    func testVerifiedCatalogAliasesPricesAndNoSymbolMatching() throws {
        let catalog=try AptosMarkets.decodeCatalog(fixture("catalog"))
        XCTAssertEqual(catalog.tokens["native"]?.symbol,"APT")
        XCTAssertGreaterThan(catalog.tokens.count,2)
        let usdc=try AptosIdentity.reference("0xbae207659db88bea0cbead6da0ed00aac12edcdda169e591cd41c94180b46f3b")
        XCTAssertEqual(catalog.tokens[usdc]?.decimals,6)
        let prices=try AptosMarkets.decodePrices(fixture("prices"),references:["native",usdc,Self.token])
        let fallback=try AptosMarkets.decodeDexPrices(fixture("dex"),references:[usdc]);XCTAssertEqual(fallback.count,1)
        XCTAssertEqual(prices.count,2);XCTAssertNil(prices.first{$0.reference==Self.token})
        XCTAssertEqual(catalog.enrich(.init(reference:usdc,name:"Spoof",symbol:"USDC",decimals:18,logo:nil,verified:false)).verified,false)
        var rows=try JSONDecoder().decode(AptosJSON.self,from:fixture("prices")).array!
        var row=rows[0].fields!;row["chainId"] = .number("2");rows=[.object(row)]
        XCTAssertTrue(try AptosMarkets.decodePrices(JSONEncoder().encode(AptosJSON.array(rows)),references:["native"]).isEmpty)
    }
}
private actor AptosArchiveTransport:AnkrTransport {
    let receipt:Data
    var requests:[URL]=[]
    init(receipt:Data){self.receipt=receipt}
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        requests.append(request.url!)
        switch request.url!.host {
        case "rpc.ankr.com":return(Data(),404)
        case "api.mainnet.aptoslabs.com":return(Data(),410)
        default:return(receipt,200)
        }
    }
}
private actor AptosFixtureTransport:AnkrTransport {
    let indexFailure:Bool,wrongOwner:Bool,wrongStore:Bool,pairedCoin:Bool
    let cancelStage: String?
    var active=0,maximum=0,total=0
    init(indexFailure:Bool=false,wrongOwner:Bool=false,wrongStore:Bool=false,pairedCoin:Bool=false,cancelStage:String?=nil) {self.cancelStage=cancelStage;self.indexFailure=indexFailure;self.wrongOwner=wrongOwner;self.wrongStore=wrongStore;self.pairedCoin=pairedCoin}
    func counts()->(Int,Int){(total,maximum)}
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        active+=1;maximum=max(maximum,active);total+=1
        defer{active-=1};try await Task.sleep(for:.milliseconds(1))
        let body=(try? JSONDecoder().decode(AptosJSON.self,from:request.httpBody ?? Data())) ?? .null
        let owner=AptosTests.owner,token=AptosTests.token
        var result:AptosJSON = .null
        if request.url!.path.hasSuffix("graphql") {
            if cancelStage == "discovery" { throw CancellationError() }
            if indexFailure {return (Data("{}".utf8),429)}
            if body["query"].string?.contains("processor_status")==true {
                result = .object(["data":.object(["ledger_infos":.array([.object(["chain_id":.number("1")])]),"processor_status":.array([.object(["last_success_version":.number("1000")])])])])
            } else {
                let row:AptosJSON = .object(["owner_address":.string(wrongOwner ? token:owner),"storage_id":.string(try AptosIdentity.address("0xffff")),"asset_type":.string(token),"asset_type_v2":.string(token),"is_primary":.bool(false),"amount":.string("20"),"amount_v2":.string("20"),"metadata":.object(["name":.string("Example"),"symbol":.string("EX"),"decimals":.number("8")])])
                var rows=[row]
                if pairedCoin {
                    var primary=row.fields!
                    primary["storage_id"] = .string(try AptosIdentity.address("0x1111"))
                    primary["asset_type_v1"] = .string("0xabc::coin::Example")
                    primary["is_primary"] = .bool(true)
                    primary["amount_v1"] = .string("4");primary["amount_v2"] = .string("6")
                    primary["amount"] = .string("10")
                    rows.insert(.object(primary),at:0)
                }
                result = .object(["data":.object(["current_fungible_asset_balances":.array(rows)])])
            }
        } else if request.url!.path.hasSuffix("view") {
            let fn=body["function"].string!
            if cancelStage == "holding", fn == "0x1::primary_fungible_store::balance" { throw CancellationError() }
            switch fn {
            case "0x1::coin::balance":result = .array([.string(body["type_arguments"].array?.first?.string==AptosIdentity.coin ? "9007199254740993":"10")])
            case "0x1::primary_fungible_store::balance":result = .array([.string("10")])
            case "0x1::object::owner":result = .array([.string(wrongStore ? token:owner)])
            case "0x1::fungible_asset::store_metadata":result = .array([.object(["inner":.string(token)])])
            case "0x1::dispatchable_fungible_asset::derived_balance":result = .array([.string("20")])
            default:throw AptosError.malformed
            }
        } else {result = .object(["chain_id":.number("1"),"ledger_version":.string("1000")])}
        return (try JSONEncoder().encode(result),200)
    }
}

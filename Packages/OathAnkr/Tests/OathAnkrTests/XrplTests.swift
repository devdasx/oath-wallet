import Foundation
import XCTest
@testable import OathAnkr

private actor XrplTransport:AnkrTransport {
    let handler:@Sendable (URLRequest) async throws -> (Data,Int)
    var active = 0, maximum = 0
    init(_ handler:@escaping @Sendable (URLRequest) async throws -> (Data,Int)) { self.handler = handler }
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        active += 1; maximum = max(active,maximum); defer { active -= 1 }; return try await handler(request)
    }
    func stats() -> (Int,Int) { (active,maximum) }
}
@MainActor final class XrplTests:XCTestCase {
    nonisolated static let owner = "r9cZA1mLK5R5Am25ArfXFmqgNwjZgnfk59"
    nonisolated static let issuer = "rMxCKbEDwqr76QuheSUMdEGf4B9xJ8m5De"
    nonisolated static let rlusd = "524C555344000000000000000000000000000000."+issuer
    nonisolated static let ledgerHash = String(repeating:"A",count:64)
    var ledger:XrplLedger { .init(hash:Self.ledgerHash,height:123,timestamp:1700000000) }
    nonisolated static func response(_ fields:[String:XrplJSON]) throws -> (Data,Int) {
        var v = fields; v["status"] = .string("success"); v["validated"] = .bool(true); v["ledger_hash"] = .string(ledgerHash); v["ledger_index"] = .number("123")
        return (try JSONEncoder().encode(XrplJSON.object(["result":.object(v)])),200)
    }
    func fixture(_ name:String) throws -> Data { try Data(contentsOf:Bundle.module.url(forResource:name,withExtension:"json",subdirectory:"Fixtures/Xrpl")!) }
    func testAddressAndIssuedCurrencyIdentity() throws {
        XCTAssertEqual(try XrplIdentity.address(Self.owner),Self.owner)
        XCTAssertThrowsError(try XrplIdentity.address(Self.owner.lowercased()))
        XCTAssertThrowsError(try XrplIdentity.address("r9cZA1mLK5R5Am25ArfXFmqgNwjZgnfk58"))
        XCTAssertEqual(try XrplIdentity.currency("0000000000000000000000005553440000000000"),"USD")
        XCTAssertNotEqual(try XrplIdentity.reference("USD."+Self.issuer),try XrplIdentity.reference("usd."+Self.issuer))
        XCTAssertNotEqual(try XrplIdentity.reference("USD."+Self.issuer),try XrplIdentity.reference("USD."+Self.owner))
        XCTAssertThrowsError(try XrplIdentity.reference("XRP."+Self.issuer))
    }
    func testExactIssuedExponentBoundsAndSignedArithmetic() throws {
        XCTAssertEqual(try XrplIdentity.issuedAmount("1e-81"),"1"+String(repeating:"0",count:15))
        XCTAssertEqual(try XrplIdentity.issuedAmount("9999999999999999e80").count,192)
        XCTAssertEqual(try XrplIdentity.issuedAmount("-0.035783526070515"),"-35783526070515"+String(repeating:"0",count:81))
        XCTAssertEqual(try XrplIdentity.issuedAmount("-0"),"0")
        for bad in ["1e-82","1e96","1.1234567890123456","nan","1e999","+1","1.2.3"] { XCTAssertThrowsError(try XrplIdentity.issuedAmount(bad),bad) }
    }
    func testInventoryPaginationIncludingEmptyFilteredObjectPage() async throws {
        let t = XrplTransport { request in
            let body = try JSONDecoder().decode(XrplJSON.self,from:request.httpBody!), p = body["params"].array![0]
            XCTAssertEqual(p["ledger_hash"].string,Self.ledgerHash)
            switch body["method"].string {
            case "account_info": return try Self.response(["account_data":.object(["Account":.string(Self.owner),"Balance":.string("123456789")])])
            case "account_lines":
                let currency = p["marker"].isNull ? "USD":"EUR"
                var fields:[String:XrplJSON] = ["account":.string(Self.owner),"lines":.array([.object(["currency":.string(currency),"account":.string(Self.issuer),"balance":.string(currency == "USD" ? "-4.2":"5.5")])])]
                if p["marker"].isNull { fields["marker"] = .string("next") }; return try Self.response(fields)
            case "account_objects":
                var fields:[String:XrplJSON] = ["account":.string(Self.owner),"account_objects":.array([])]
                if p["marker"].isNull { fields["marker"] = .string("filtered-page") }; return try Self.response(fields)
            default: throw XrplError.malformed
            }
        }
        let value = try await XrplClient(endpoint:URL(string:"https://example.test")!,transport:t).inventory(owner:Self.owner,at:ledger)
        XCTAssertEqual(value.holdings.count,3)
        XCTAssertEqual(value.holdings.first{$0.reference == "native"}?.amount,"123456789")
        XCTAssertTrue(value.holdings.first{$0.reference.hasPrefix("USD.")}!.amount.hasPrefix("-"))
    }
    func testMissingAndWrongLedgerNeverConflateProviderFailureWithZero() async throws {
        for code in ["actNotFound","tooBusy"] {
            let t = XrplTransport { _ in try Self.response(["account":.string(Self.owner),"error":.string(code)]) }
            do { let value = try await XrplClient(endpoint:URL(string:"https://example.test")!,transport:t).inventory(owner:Self.owner,at:ledger); XCTAssertEqual(code,"actNotFound"); XCTAssertFalse(value.exists) }
            catch { XCTAssertEqual(code,"tooBusy") }
        }
        let t = XrplTransport { _ in (Data("{\"result\":{\"status\":\"success\",\"validated\":false}}".utf8),200) }
        do { _ = try await XrplClient(endpoint:URL(string:"https://example.test")!,transport:t).inventory(owner:Self.owner,at:ledger); XCTFail() } catch { XCTAssertEqual(error as? XrplError,.wrongLedger) }
    }
    func testParallelLimitFallbackAndCancellation() async throws {
        let data = try fixture("mpt-issuance"), mpt = "0641C792F9C6BB3B75EA31B353A54E2EFAC423498EF25045"
        let value = try JSONDecoder().decode(XrplJSON.self,from:data)["result"]["node"]
        let t = XrplTransport { request in
            try await Task.sleep(for:.milliseconds(25))
            if request.url!.host == "rpc.ankr.com" { return (Data(),503) }
            XCTAssertFalse(request.url!.absoluteString.contains("fixturesecret"))
            return try Self.response(["node":value])
        }
        let client = try XrplClient(apiKey:"fixturesecret",transport:t), ledger = ledger
        try await withThrowingTaskGroup(of:Void.self) { group in
            for _ in 0..<15 { group.addTask { let token = try await client.token(mpt,ledger:ledger); XCTAssertEqual(token.decimals,0) } }; try await group.waitForAll()
        }
        var stats = await t.stats(); XCTAssertGreaterThan(stats.1,1); XCTAssertLessThanOrEqual(stats.1,6)
        let job = Task { try await client.token(mpt,ledger:ledger) }; job.cancel()
        do { _ = try await job.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        stats = await t.stats(); XCTAssertEqual(stats.0,0)
    }
    func testLiveHistoryFixturesAndPartialPaymentActualDelivery() throws {
        for (name,owner) in [("old-account_tx",Self.owner),("holder-account_tx","rLxePHrWeHbkg8yy83fWxnxXmYbwmuMK9Q"),("holder2-account_tx","rHJ57KNiiPtwiqpmhJRzRYUEmFTkrkEebC")] {
            let rows = try JSONDecoder().decode(XrplJSON.self,from:fixture(name))["result"]["transactions"].array!
            for row in rows { let tx = try XrplDecoding.transaction(row,owner:owner); XCTAssertFalse(tx.movements.isEmpty); XCTAssertEqual(tx.hash,row["hash"].string) }
        }
        // A hostile partial-payment request asks for 1,000,000 XRP, but the
        // validated ledger credits 1 XRP. Only the actual change is displayed.
        let node:XrplJSON = .object(["ModifiedNode":.object(["LedgerEntryType":.string("AccountRoot"),"FinalFields":.object(["Account":.string(Self.owner),"Balance":.string("11000000")]),"PreviousFields":.object(["Balance":.string("10000000")])])])
        let row:XrplJSON = .object(["hash":.string(Self.ledgerHash),"ledger_index":.number("123"),"validated":.bool(true),"tx_json":.object(["Account":.string(Self.issuer),"Destination":.string(Self.owner),"TransactionType":.string("Payment"),"DeliverMax":.string("1000000000000"),"Flags":.number("131072"),"Fee":.string("12"),"date":.number("800000000")]),"meta":.object(["TransactionResult":.string("tesSUCCESS"),"AffectedNodes":.array([node])])])
        let tx = try XrplDecoding.transaction(row,owner:Self.owner)
        XCTAssertEqual(tx.movements.first?.amount,"1000000"); XCTAssertEqual(tx.movements.first?.direction,"incoming")
    }
    func testIssuedLowHighPerspectiveAndNativeFeeAreExact() throws {
        let line:XrplJSON = .object(["ModifiedNode":.object(["LedgerEntryType":.string("RippleState"),"FinalFields":.object(["LowLimit":.object(["issuer":.string(Self.issuer)]),"HighLimit":.object(["issuer":.string(Self.owner)]),"Balance":.object(["currency":.string("USD"),"value":.string("-15")])]),"PreviousFields":.object(["Balance":.object(["currency":.string("USD"),"value":.string("-10")])])])])
        let native:XrplJSON = .object(["ModifiedNode":.object(["LedgerEntryType":.string("AccountRoot"),"FinalFields":.object(["Account":.string(Self.owner),"Balance":.string("8999988")]),"PreviousFields":.object(["Balance":.string("10000000")])])])
        let row:XrplJSON = .object(["hash":.string(Self.ledgerHash),"ledger_index":.number("123"),"validated":.bool(true),"tx_json":.object(["Account":.string(Self.owner),"TransactionType":.string("OfferCreate"),"Fee":.string("12"),"date":.number("800000000")]),"meta":.object(["TransactionResult":.string("tesSUCCESS"),"AffectedNodes":.array([line,native])])])
        let tx = try XrplDecoding.transaction(row,owner:Self.owner)
        XCTAssertEqual(tx.movements.first{$0.reference == "native"}?.amount,"1000000")
        XCTAssertEqual(tx.movements.first{$0.reference != "native"}?.amount,try XrplIdentity.issuedAmount("5"))
        XCTAssertEqual(tx.movements.first{$0.reference != "native"}?.direction,"incoming"); XCTAssertNil(tx.counterparty)
    }
    func testHistoryRejectsPrunedRangeAndRepeatingMarker() async throws {
        for pruned in [true,false] {
            let fixture = try JSONDecoder().decode(XrplJSON.self,from:fixture("old-account_tx"))["result"]["transactions"]
            let t = XrplTransport { _ in try Self.response(["account":.string(Self.owner),"ledger_index_min":.number(pruned ? "100000000":"32570"),"ledger_index_max":.number("200000000"),"transactions":fixture,"marker":.string("same")]) }
            do { _ = try await XrplClient(endpoint:URL(string:"https://example.test")!,transport:t).history(owner:Self.owner,before:"\"same\"",upperLedger:200000000); XCTFail() }
            catch { XCTAssertEqual(error as? XrplError,pruned ? .incompleteHistory:.paginationLoop) }
        }
    }

    func testHistoryFailsOverForLedger58AndClampedResponsesWithoutChangingCursor() async throws {
        for failure in ["lgrIdxMalformed","clamped","pruned"] {
            let transport = XrplTransport { request in
                let body = try JSONDecoder().decode(XrplJSON.self,from:request.httpBody!), p = body["params"].array![0]
                XCTAssertEqual(body["method"].string,"account_tx")
                XCTAssertEqual(p["ledger_index_max"].text,"200000000")
                XCTAssertEqual(p["marker"].string,"saved")
                if request.url!.host == "primary.test", failure == "lgrIdxMalformed" {
                    return (Data(#"{"result":{"status":"error","error":"lgrIdxMalformed","error_code":58,"error_message":"Ledger index malformed."}}"#.utf8),200)
                }
                let primary = request.url!.host == "primary.test"
                return try Self.response(["account":.string(Self.owner),
                    "ledger_index_min":.number(primary && failure == "pruned" ? "100000000":"32570"),
                    "ledger_index_max":.number(primary && failure == "clamped" ? "199999999":"200000000"),"transactions":.array([])])
            }
            let client = try XrplClient(endpoint:URL(string:"https://primary.test")!,fallback:URL(string:"https://fallback.test")!,transport:transport)
            let page = try await client.history(owner:Self.owner,before:"\"saved\"",upperLedger:200000000)
            XCTAssertEqual(page.upperLedger,200000000); XCTAssertNil(page.next)
        }
    }
    func testPricesRequireExactIssuerAndLiquidMarket() throws {
        let data = try fixture("dex-rlusd")
        XCTAssertNotNil(try XrplMarkets.decodeDexPrice(data,reference:Self.rlusd))
        XCTAssertNil(try XrplMarkets.decodeDexPrice(data,reference:"524C555344000000000000000000000000000000."+Self.owner))
        let changed = String(decoding:data,as:UTF8.self).replacingOccurrences(of:"\"xrpl\"",with:"\"ethereum\"")
        XCTAssertNil(try XrplMarkets.decodeDexPrice(Data(changed.utf8),reference:Self.rlusd))
    }
    func testLiveFourAccountsAgainstIndependentValidatedLedgerAndPrices() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_XRPL_LIVE_KEY"] else { throw XCTSkip("Opt-in public XRP Ledger read-only comparison") }
        let client = try XrplClient(apiKey:key), peer = try XrplClient(endpoint:URL(string:"https://xrplcluster.com")!)
        let ledger = try await client.validatedLedger()
        for owner in [Self.owner,"rLxePHrWeHbkg8yy83fWxnxXmYbwmuMK9Q","rHJ57KNiiPtwiqpmhJRzRYUEmFTkrkEebC","rsiPEXNs1XGn14DV7MHXsTfQVpGiEpJ347"] {
            async let a = client.inventory(owner:owner,at:ledger)
            async let b = peer.inventory(owner:owner,at:ledger)
            let (x,y) = try await (a,b)
            XCTAssertEqual(Dictionary(uniqueKeysWithValues:x.holdings.map{($0.reference,$0.amount)}),Dictionary(uniqueKeysWithValues:y.holdings.map{($0.reference,$0.amount)}))
            let first = try await client.history(owner:owner,upperLedger:ledger.height,limit:20)
            let comparison = try await peer.history(owner:owner,upperLedger:ledger.height,limit:20)
            XCTAssertEqual(first.transactions.map(\.hash),comparison.transactions.map(\.hash))
            XCTAssertFalse(first.transactions.isEmpty)
            if let next = first.next { let second = try await client.history(owner:owner,before:next,upperLedger:first.upperLedger,limit:20); XCTAssertTrue(Set(first.transactions.map(\.hash)).isDisjoint(with:second.transactions.map(\.hash))) }
            print("XRPL live matched holdings=\(x.holdings.count), history=\(first.transactions.count), ledger=\(ledger.height)")
        }
        let markets = XrplMarkets(), catalog = try await markets.catalog()
        XCTAssertTrue(catalog.contains(Self.rlusd))
        async let native = markets.nativePrice()
        async let quote = markets.prices(references:["native",Self.rlusd],catalog:catalog)
        async let dex = markets.dexPrice(reference:Self.rlusd)
        let (n,q,d) = try await (native,quote,dex)
        let cgNative = try XCTUnwrap(q.first{$0.reference == "native"}), cgUSD = try XCTUnwrap(q.first{$0.reference == Self.rlusd}), dexUSD = try XCTUnwrap(d)
        XCTAssertEqual(try XCTUnwrap(Double(n.usd)),try XCTUnwrap(Double(cgNative.usd)),accuracy:try XCTUnwrap(Double(n.usd))*0.05)
        XCTAssertEqual(try XCTUnwrap(Double(dexUSD.usd)),try XCTUnwrap(Double(cgUSD.usd)),accuracy:0.05)
        print("XRPL live Coinbase/CoinGecko XRP and CoinGecko/DEX RLUSD prices agree within 5%; catalog identities=\(catalog.ids.count)")
    }
}

import XCTest
@testable import OathAnkr

final class IoTeXTests: XCTestCase, @unchecked Sendable {
    private func json(_ object: Any) throws -> SolanaJSON {
        try JSONDecoder().decode(SolanaJSON.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func fixture() throws -> SolanaJSON {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "swap", withExtension: "json", subdirectory: "Fixtures/IoTeX"))
        return try JSONDecoder().decode(SolanaJSON.self, from: Data(contentsOf: url))
    }
    private func block(_ receipt: SolanaJSON) -> SolanaJSON {
        .object(["hash": receipt["blockHash"], "number": receipt["blockNumber"], "timestamp": .string("1793256690")])
    }
    func testNetworkAndAddressAliases() throws {
        XCTAssertEqual(IndexedEVMChain.iotex.chainID, 4689)
        XCTAssertEqual(IndexedEVMChain.iotex.rpcPath, "iotex")
        XCTAssertEqual(IndexedEVMToken.native(.iotex).symbol, "IOTX")
        XCTAssertNil(AnkrChain(networkID: "iotex"))
        let native = "io1d77dcytfk5fsck089eg7669gfpqunrx35ue5ln"
        let evm = "0x6fbcdc1169b5130c59e72e51ed68a84841c98cd1"
        XCTAssertEqual(try IoTeXIdentity.ethereum(native), evm)
        XCTAssertEqual(try IoTeXIdentity.native(evm), native)
        XCTAssertEqual(try IoTeXIdentity.ethereum(native.uppercased()), evm)
        for bad in [native.dropLast()+"a", "iO"+native.dropFirst(2), "it"+native.dropFirst(2), "0x123", native+"q"] {
            XCTAssertThrowsError(try IoTeXIdentity.ethereum(String(bad)))
        }
        XCTAssertEqual(try TokenDiscoveryNetworks.canonical(native, network: "iotex"), evm)
        let data = try JSONSerialization.data(withJSONObject: [["id":"token","platforms":["iotex":native,"ethereum":evm]]])
        XCTAssertEqual(try IndexedEVMMarkets.decodeCatalog(data, chain: .iotex).ids, [evm:"token"])
    }
    func testNativeReceiptFailureCodesNeverBecomeSuccessfulTransfers() throws {
        XCTAssertTrue(try IoTeXIndex.succeeded(json(["status":"0x1"])))
        for status in ["0x0", "0x65", "0x6a", "0xc9", "215"] { XCTAssertFalse(try IoTeXIndex.succeeded(json(["status":status]))) }
        XCTAssertThrowsError(try IoTeXIndex.succeeded(json(["status":"invalid"])))
    }
    func testPaginationAndProviderFailuresCannotBecomeEmptyInventory() throws {
        let item: [String: Any] = ["TokenAddress": "0x1111111111111111111111111111111111111111", "TokenName": "One", "TokenSymbol": "ONE", "TokenDivisor": 18]
        let page = try IoTeXIndex.inventory(json(["status":"1","result":Array(repeating:item,count:50)]), page: 2)
        XCTAssertEqual(page["next_page_params"]["page"].text,"3")
        XCTAssertTrue(page["items"].array?.first?["token"]["decimals"].isNull == true)
        XCTAssertThrowsError(try IoTeXIndex.rows(json(["status":"0","message":"Rate limit","result":[]])))
        XCTAssertThrowsError(try IoTeXIndex.parameters(["page":.number("2")], history:true))
        XCTAssertThrowsError(try IoTeXIndex.parameters(["page":.number("0")], history:false))
        XCTAssertThrowsError(try IoTeXIndex.parameters(["page":.number("2"),"url":.string("elsewhere")], history:false))
        let cursor = try IoTeXIndex.parameters(["page":.number("2"),"endblock":.number("100")], history:true)
        XCTAssertEqual(cursor.page,2); XCTAssertEqual(cursor.end,100)
    }
    func testRealSwapReceiptRetainsBothTokensWithStableIDs() throws {
        let f = try fixture(), receipt = f["receipt"], hash = try XCTUnwrap(receipt["transactionHash"].string)
        let owner = "0x53bdd401a871bd0f84e94619edcc0c24489d4aab"
        let rows = try IoTeXIndex.transfers(hash:hash,receipt:receipt,block:block(receipt),owner:owner)
        XCTAssertEqual(rows.count,2)
        XCTAssertEqual(Set(rows.compactMap{$0["log_index"].text}).count,2)
        XCTAssertEqual(Set(rows.compactMap{$0["token"]["address_hash"].string}), ["0xa00744882684c3e4747faefd68d283ea44099d03","0x17df9fbfc1cdab0f90eddc318c4f6fcada730cf2"])
        XCTAssertEqual(rows,try IoTeXIndex.transfers(hash:hash,receipt:receipt,block:block(receipt),owner:owner))
        XCTAssertThrowsError(try IoTeXIndex.transfers(hash:"0x"+String(repeating:"a",count:64),receipt:receipt,block:block(receipt),owner:owner))
        // Unknown accounts cannot acquire someone else's transfer events.
        XCTAssertTrue(try IoTeXIndex.transfers(hash:hash,receipt:receipt,block:block(receipt),owner:"0x1111111111111111111111111111111111111111").isEmpty)
    }
    func testLegacyRepeatedLogIndicesKeepDistinctTransfers() throws {
        let f = try fixture()
        guard case .object(var receipt) = f["receipt"] else { return XCTFail("Expected receipt") }
        receipt["logs"] = .array(try XCTUnwrap(receipt["logs"]?.array).map { log in
            guard case .object(var fields) = log else { return log }
            fields["logIndex"] = .string("0x0")
            return .object(fields)
        })
        let value = SolanaJSON.object(receipt), hash = try XCTUnwrap(value["transactionHash"].string)
        let rows = try IoTeXIndex.transfers(hash: hash, receipt: value, block: block(value), owner: "0x53bdd401a871bd0f84e94619edcc0c24489d4aab")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.compactMap { $0["log_index"].text }).count, 2)
        XCTAssertEqual(rows, try IoTeXIndex.transfers(hash: hash, receipt: f["receipt"], block: block(value), owner: "0x53bdd401a871bd0f84e94619edcc0c24489d4aab"))
    }
    func testCommittedNativeLogsExcludeFeesAndExternalValue() throws {
        let f = try fixture(), receipt = f["receipt"], hash = try XCTUnwrap(receipt["transactionHash"].string)
        let url = try XCTUnwrap(Bundle.module.url(forResource:"native-logs",withExtension:"bin",subdirectory:"Fixtures/IoTeX"))
        let bytes = try Data(contentsOf:url), logs = try IoTeXNativeLogs.decode(bytes)
        let rows = try logs.movements(hash:hash,receipt:receipt,transaction:f["transaction"],block:block(receipt),owner:"0xa6eb3902ca74265b7e5a1f66d39fa0cec0ca38ff")
        XCTAssertEqual(rows.count,2)
        XCTAssertEqual(Set(rows.compactMap{$0["value"].text}),["8427600752808916610","42138003764044583"])
        XCTAssertThrowsError(try IoTeXNativeLogs.decode(Data(bytes.dropLast())))
        XCTAssertThrowsError(try IoTeXNativeLogs.decode(Data([1])+bytes.dropFirst()))
        XCTAssertThrowsError(try logs.movements(hash:"0x"+String(repeating:"a",count:64),receipt:receipt,transaction:f["transaction"],block:block(receipt),owner:"0xa6eb3902ca74265b7e5a1f66d39fa0cec0ca38ff"))
    }
    func testConflictingBridgeQuoteIsUnavailableInsteadOfAssumingAPeg() throws {
        let reference = "0x6fbcdc1169b5130c59e72e51ed68a84841c98cd1"
        let quote = IndexedEVMPrice(chain:.iotex,reference:reference,usd:"0.73",source:"CoinGecko",fetchedAt:.now)
        func response(_ price: String) throws -> Data {
            try JSONSerialization.data(withJSONObject:["data":[["id":"iotx_"+reference,"type":"token","attributes":["address":reference,"price_usd":price,"total_reserve_in_usd":"8000"]]]])
        }
        XCTAssertTrue(try IndexedEVMMarkets.corroborateIoTeXPrices([quote],data:response("0.53")).isEmpty)
        XCTAssertEqual(try IndexedEVMMarkets.corroborateIoTeXPrices([quote],data:response("0.74")).count,1)
    }
    func testNativeExplorerPriceRequiresFreshTimestampAndPositiveValue() throws {
        let now = Date(timeIntervalSince1970: 1_793_260_000)
        func data(_ price: String, _ timestamp: Double, status: String = "1") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["status":status,"result":["ethusd":price,"ethusd_timestamp":timestamp]])
        }
        let quote = try IndexedEVMMarkets.decodeIoTeXNativePrice(data("0.0036", now.timeIntervalSince1970), now: now)
        XCTAssertEqual(quote.chain, .iotex); XCTAssertEqual(quote.reference, "native"); XCTAssertEqual(quote.usd, "0.0036")
        for (price, time) in [("0",now.timeIntervalSince1970),("-1",now.timeIntervalSince1970),("0.0036",now.timeIntervalSince1970 - 901),("0.0036",now.timeIntervalSince1970 + 61)] {
            XCTAssertThrowsError(try IndexedEVMMarkets.decodeIoTeXNativePrice(data(price,time),now:now))
        }
        XCTAssertThrowsError(try IndexedEVMMarkets.decodeIoTeXNativePrice(data("0.0036",now.timeIntervalSince1970,status:"0"),now:now))
    }
    func testDEXIdentityActivityAndFreshnessGates() throws {
        let ref = IndexedEVMChain.iotex.wrappedNative
        func data(_ network: String,_ volume:String) throws -> Data {
            try JSONSerialization.data(withJSONObject:["data":[["id":network+"_"+ref,"type":"token","attributes":["address":ref,"price_usd":"0.0036","total_reserve_in_usd":"20000","volume_usd":["h24":volume]]]]])
        }
        XCTAssertEqual(try IndexedEVMMarkets.decodeTerminalDEX(data("iotx","10000"),chain:.iotex,references:[ref]).first?.usd,"0.0036")
        XCTAssertTrue(try IndexedEVMMarkets.decodeTerminalDEX(data("iotx","0"),chain:.iotex,references:[ref]).isEmpty)
        XCTAssertThrowsError(try IndexedEVMMarkets.decodeTerminalDEX(data("eth","10000"),chain:.iotex,references:[ref]))
        let stale = try json(["coins":["coingecko:iotex":["price":10,"confidence":0.99,"timestamp":Date().timeIntervalSince1970-3600]]])
        XCTAssertThrowsError(try NativePriceFallback.decodeLlama(stale,key:"coingecko:iotex"))
    }
}

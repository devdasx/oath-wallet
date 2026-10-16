import Foundation
import XCTest
@testable import OathAnkr

final class SolanaTests: XCTestCase, @unchecked Sendable {
    let owner = "H31vEBxSJk1nQdUN11qZgZyhScyShhscKhvhZZU3dQoU"
    let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
    let token = "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk"
    let signature = String(repeating: "1", count: 64)
    func json(_ value: Any) throws -> SolanaJSON { try JSONDecoder().decode(SolanaJSON.self, from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) }
    func values(amount: String = "9007199254740993", otherOwner: String? = nil, program: String? = nil) throws -> [SolanaJSON] {
        let entry: [String: Any] = ["pubkey": token, "account": ["owner": program ?? SolanaIdentity.tokenProgram,
            "data": ["parsed": ["type": "account", "info": ["owner": otherOwner ?? owner,"mint":mint,"state":"frozen",
                "tokenAmount":["amount":amount,"decimals":6]]]]]]
        return try [json(["context":["slot":123],"value":UInt64.max]),
                    json(["context":["slot":123],"value":[entry]]),json(["context":["slot":124],"value":[]])]
    }
    func tx(failed: Bool = false, ownerInKeys: Bool = true) throws -> SolanaJSON {
        let keys = ownerInKeys ? [owner,token] : [mint,token]
        func balance(_ amount: String) -> [String: Any] { ["accountIndex":1,"mint":mint,"owner":owner,"uiTokenAmount":["amount":amount,"decimals":6]] }
        return try json(["slot":123,"blockTime":1_700_000_000,
            "transaction":["signatures":[signature],"message":["accountKeys":keys.map { ["pubkey":$0] }]],
            "meta":["err":failed ? ["InstructionError":[0,1]] as Any : NSNull(), "fee":5000,
                    "preBalances":[100005000,2039280],"postBalances":[80000000,2039280],
                    "preTokenBalances":[balance("9007199254740993")],"postTokenBalances":[balance("9007199254840993")]]])
    }
    func testExactBalancesFrozenTokensAndValidation() throws {
        let inventory = try SolanaDecoding.inventory(owner: owner, values: values())
        XCTAssertEqual(inventory.lamports,"18446744073709551615")
        XCTAssertEqual(inventory.accounts[0].amount,"9007199254740993")
        XCTAssertTrue(inventory.accounts[0].frozen)
        XCTAssertThrowsError(try SolanaDecoding.inventory(owner: owner, values: values(amount: "-1")))
        XCTAssertThrowsError(try SolanaDecoding.inventory(owner: owner, values: values(amount: "1.5")))
        XCTAssertThrowsError(try SolanaDecoding.inventory(owner: owner, values: values(otherOwner: token)))
        XCTAssertThrowsError(try SolanaDecoding.inventory(owner: owner, values: values(program: mint)))
        var missing = try values(); missing[2] = .null
        XCTAssertThrowsError(try SolanaDecoding.inventory(owner: owner, values: missing))
        XCTAssertFalse(SolanaIdentity.isAddress(String(repeating:"1",count:33)))
        XCTAssertTrue(SolanaIdentity.isAddress(String(repeating:"1",count:32)))
    }
    func testNetTokenChangesFeesFailedTransactionsAndTokenOnlyDeposits() throws {
        let result = try SolanaDecoding.transaction(tx(), signature: signature, owner: owner)
        XCTAssertEqual(result.fee,"5000")
        XCTAssertEqual(result.changes.first { $0.mint == "native" }?.amount,"20000000")
        XCTAssertEqual(result.changes.first { $0.mint == mint }?.amount,"100000")
        XCTAssertEqual(result.changes.first { $0.mint == mint }?.direction,"incoming")
        XCTAssertEqual(result.tokenAccounts,[token])
        let failed = try SolanaDecoding.transaction(tx(failed: true), signature: signature, owner: owner)
        XCTAssertTrue(failed.failed); XCTAssertEqual(failed.changes.map(\.amount),["0", "0"])
        XCTAssertEqual(Set(failed.changes.map(\.mint)), ["native", mint])
        let deposit = try SolanaDecoding.transaction(tx(ownerInKeys:false), signature:signature,owner:owner)
        XCTAssertEqual(deposit.changes.count,1)
        XCTAssertEqual(deposit.changes[0].mint,mint)
        XCTAssertThrowsError(try SolanaDecoding.transaction(tx(), signature:String(repeating:"2",count:64),owner:owner))
        let foreign = try SolanaDecoding.transaction(tx(), signature:signature,owner:"11111111111111111111111111111111")
        XCTAssertTrue(foreign.changes.isEmpty, "Old token-account ownership must not block history or create another owner's activity")
    }
    func testBatchRepliesAreMatchedByIDAndCheckedIndividually() async throws {
        let values = try values()
        let transport = SolanaFixtureTransport { request in
            let root = try JSONDecoder().decode(SolanaJSON.self, from: request.httpBody!)
            if root["method"].string == "getGenesisHash" { return .object(["jsonrpc":.string("2.0"),"id":.number("1"),"result":.string(SolanaIdentity.genesis)]) }
            return .array(values.enumerated().reversed().map { i, value in .object(["jsonrpc":.string("2.0"),"id":.number(String(i+1)),"result":value]) })
        }
        let client = try SolanaClient(apiKey:"test",transport:transport)
        let result = try await client.inventory(owner:owner)
        XCTAssertEqual(result.accounts[0].mint,mint)
        XCTAssertEqual(result.lamports,String(UInt64.max))
        let bad = SolanaFixtureTransport { request in
            let root = try JSONDecoder().decode(SolanaJSON.self,from:request.httpBody!)
            if root["method"].string == "getGenesisHash" { return .object(["jsonrpc":.string("2.0"),"id":.number("1"),"result":.string("wrong-network")]) }
            throw SolanaError.malformed
        }
        do { _ = try await SolanaClient(apiKey:"test",transport:bad).inventory(owner:owner); XCTFail() }
        catch { XCTAssertEqual(error as? SolanaError,.wrongNetwork) }
    }
    func testAnkrNullTransactionFallsBackToArchive() async throws {
        let transaction = try tx()
        let transport = SolanaFixtureTransport { request in
            let root = try JSONDecoder().decode(SolanaJSON.self,from:request.httpBody!)
            let result: SolanaJSON
            if root["method"].string == "getGenesisHash" { result = .string(SolanaIdentity.genesis) }
            else { result = request.url!.host == "rpc.ankr.com" ? .null : transaction }
            return .object(["jsonrpc":.string("2.0"),"id":.number("1"),"result":result])
        }
        let result = try await SolanaClient(apiKey:"test",transport:transport).transactions(signatures:[signature],owner:owner)
        XCTAssertEqual(result.count,1); XCTAssertEqual(result[0].signature,signature)
    }
    func testHTTP200RateLimitedMemberRetriesOnlyThatID() async throws {
        let signatures = [signature, String(repeating: "1", count: 63) + "2", String(repeating: "1", count: 63) + "3"]
        let transport = SolanaRateLimitTransport(transaction: try tx())
        let result = try await SolanaClient(apiKey: "test", transport: transport).transactions(signatures: signatures, owner: owner)
        XCTAssertEqual(result.map(\.signature), signatures)
        let batches = await transport.transactionBatches
        XCTAssertEqual(batches, [[1, 2, 3], [2]], "Do not repeat successful RPC members or renumber a retried reply")
    }
    func testPricesMatchMintNotSymbolOrQuoteTokenAndChooseDeepestPool() throws {
        func pair(_ base: String, price: String, depth: Int) -> [String:Any] {
            ["chainId":"solana","baseToken":["address":base,"symbol":"USDC"],"quoteToken":["address":mint],"priceUsd":price,"liquidity":["usd":depth]]
        }
        let data = try JSONSerialization.data(withJSONObject:[pair(token,price:"500",depth:9999999),pair(mint,price:"2",depth:10),pair(mint,price:"0.9999",depth:100000)])
        let result = try SolanaMarkets.decodePrices(data,mints:[mint])
        XCTAssertEqual(result.count,1); XCTAssertEqual(result[0].usd,"0.9999")
        XCTAssertTrue(try SolanaMarkets.decodePrices(Data("[]".utf8),mints:[mint]).isEmpty)
        XCTAssertThrowsError(try SolanaMarkets.decodePrices(Data("{}".utf8),mints:[mint]))
        let invalid = try JSONSerialization.data(withJSONObject: [pair(mint, price: "2garbage", depth: 1000)])
        XCTAssertTrue(try SolanaMarkets.decodePrices(invalid, mints: [mint]).isEmpty)
    }

    func testCoinGeckoSolanaCatalogUsesNullChainID() throws {
        // Real endpoint shape: Solana has null chainId, unlike EVM token lists.
        let data = try JSONSerialization.data(withJSONObject: ["tokens": [
            ["chainId": NSNull(), "address": mint, "name": "USD Coin", "symbol": "USDC", "decimals": 6,
             "logoURI": "https://assets.coingecko.com/coins/images/6319/small/usdc.png"],
            ["chainId": 1, "address": token, "name": "Wrong network", "symbol": "WRONG", "decimals": 9]
        ]])
        let catalog = try SolanaMarkets.decodeCatalog(data)
        XCTAssertEqual(catalog.count, 1)
        XCTAssertEqual(catalog[mint]?.symbol, "USDC")
        XCTAssertEqual(catalog[mint]?.decimals, 6)
        XCTAssertNil(catalog[token])
    }

    func testMissingDexPricesUseExactMintFallbackAndKeepSource() async throws {
        let mint = mint, token = token
        let markets = SolanaMarkets(transport: SolanaFixtureTransport { request in
            if request.url?.host == "api.dexscreener.com" { return .array([]) }
            return .object(["data": .object(["type": .string("simple_token_price"), "attributes": .object([
                "token_prices": .object([mint: .string("0.0000443390945574161475785974001353229993983636192"),
                                         token: .string("99")])])])])
        })
        let quotes = try await markets.prices(mints: [mint])
        XCTAssertEqual(quotes.count, 1)
        XCTAssertEqual(quotes[0].mint, mint)
        XCTAssertEqual(quotes[0].source, "GeckoTerminal")
        XCTAssertEqual(quotes[0].usd, "0.0000443390945574161475785974001353229993983636192")
    }

    func testNativeCounterpartyRequiresAnActualParsedSystemTransfer() throws {
        guard case .object(var root) = try tx(), case .object(var transaction) = root["transaction"],
              case .object(var message) = transaction["message"] else { return XCTFail() }
        func instruction(program: String) -> SolanaJSON {
            .object(["programId": .string(program), "parsed": .object(["type": .string("transfer"),
                "info": .object(["source": .string(owner), "destination": .string(mint), "lamports": .number("20000000")])])])
        }
        message["instructions"] = .array([instruction(program: "11111111111111111111111111111111")])
        transaction["message"] = .object(message); root["transaction"] = .object(transaction)
        let parsed = try SolanaDecoding.transaction(.object(root), signature: signature, owner: owner)
        XCTAssertEqual(parsed.changes.first { $0.mint == "native" }?.counterparty, mint)
        message["instructions"] = .array([instruction(program: mint)])
        transaction["message"] = .object(message); root["transaction"] = .object(transaction)
        let fake = try SolanaDecoding.transaction(.object(root), signature: signature, owner: owner)
        XCTAssertNil(fake.changes.first { $0.mint == "native" }?.counterparty)
    }

    func testTokenTransferRetainsFeeOnlyNativeActivity() throws {
        guard case .object(var root) = try tx(), case .object(var meta) = root["meta"] else { return XCTFail() }
        meta["postBalances"] = .array([.number("100000000"), .number("2039280")])
        root["meta"] = .object(meta)
        let result = try SolanaDecoding.transaction(.object(root), signature: signature, owner: owner)
        XCTAssertEqual(result.fee, "5000")
        XCTAssertEqual(result.changes.first { $0.mint == "native" }?.amount, "0")
        XCTAssertEqual(result.changes.first { $0.mint == "native" }?.direction, "self")
        XCTAssertEqual(result.changes.first { $0.mint == mint }?.amount, "100000")
    }

    func testZeroNetTokenTransfersRemainInTokenHistory() throws {
        guard case .object(var root) = try tx(), case .object(var meta) = root["meta"],
              case .object(var transaction) = root["transaction"],
              case .object(var message) = transaction["message"] else { return XCTFail() }
        meta["postTokenBalances"] = meta["preTokenBalances"]
        message["instructions"] = .array([.object(["programId": .string(SolanaIdentity.tokenProgram),
            "parsed": .object(["type": .string("transfer"), "info": .object([
                "source": .string(token), "destination": .string(token), "amount": .string("100")])])])])
        transaction["message"] = .object(message); root["transaction"] = .object(transaction); root["meta"] = .object(meta)
        let result = try SolanaDecoding.transaction(.object(root), signature: signature, owner: owner)
        let entry = try XCTUnwrap(result.changes.first { $0.mint == mint })
        XCTAssertEqual(entry.direction, "self")
        XCTAssertEqual(entry.amount, "0")
        XCTAssertNil(entry.counterparty)
    }
}

struct SolanaFixtureTransport: AnkrTransport {
    let respond: @Sendable (URLRequest) throws -> SolanaJSON
    init(_ respond: @escaping @Sendable (URLRequest) throws -> SolanaJSON) { self.respond = respond }
    func send(_ request: URLRequest) async throws -> (Data, Int) { (try JSONEncoder().encode(respond(request)),200) }
}

private actor SolanaRateLimitTransport: AnkrTransport {
    let transaction: SolanaJSON
    private(set) var transactionBatches: [[UInt64]] = []
    init(transaction: SolanaJSON) { self.transaction = transaction }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let root = try JSONDecoder().decode(SolanaJSON.self, from: request.httpBody!)
        let calls = root.array ?? [root]
        if calls[0]["method"].string == "getTransaction" {
            transactionBatches.append(calls.compactMap { $0["id"].integer })
        }
        let results = try calls.map { call -> SolanaJSON in
            if call["method"].string == "getGenesisHash" {
                return .object(["jsonrpc": .string("2.0"), "id": call["id"], "result": .string(SolanaIdentity.genesis)])
            }
            if transactionBatches.count == 1, call["id"].integer == 2 {
                return .object(["jsonrpc": .string("2.0"), "id": call["id"], "error": .object(["code": .number("429")])])
            }
            guard case .object(var value) = transaction, case .object(var detail) = value["transaction"],
                  let signature = call["params"].array?.first else { throw SolanaError.malformed }
            detail["signatures"] = .array([signature]); value["transaction"] = .object(detail)
            return .object(["jsonrpc": .string("2.0"), "id": call["id"], "result": .object(value)])
        }
        return (try JSONEncoder().encode(root.array == nil ? results[0] : .array(results.reversed())), 200)
    }
}

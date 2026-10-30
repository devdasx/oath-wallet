import Foundation
import XCTest
@testable import OathAnkr

private actor ThorchainReviewTransport: AnkrTransport {
    let inbounds: SolanaJSON
    let pools: SolanaJSON
    var queries: [[String: String]] = []
    init(inbounds: SolanaJSON, pools: SolanaJSON) { self.inbounds = inbounds; self.pools = pools }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let url = try XCTUnwrap(request.url)
        let json: SolanaJSON
        if url.path.hasSuffix("inbound_addresses") { json = inbounds }
        else if url.path.hasSuffix("/pools") { json = pools }
        else if url.path.hasSuffix("vaults/asgard") { json = .array([]) }
        else if url.path.hasSuffix("/stats") { json = .object(["runePriceUSD": .string("0.6")]) }
        else if url.path.hasSuffix("quote/swap") {
            let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            queries.append(query)
            json = .object(["memo": .string("=:BSC.USDT:\(query["destination"]!):0/1/1"),
                "expiry": .number(String(Int(Date.now.timeIntervalSince1970) + 600)), "expected_amount_out": .string("675096000"),
                "fees": .object(["asset": .string("BSC.USDT-0X55D398326F99059FF775485246999027B3197955"),
                    "outbound": .string("23000000"), "liquidity": .string("1000000"), "affiliate": .string("0"), "slippage_bps": .number("19")]),
                "total_swap_seconds": .number("60")])
        } else { throw AnkrError.invalidResponse }
        return (try JSONEncoder().encode(json), 200)
    }
}

final class ThorchainEVMSwapReviewTests: XCTestCase {
    private let owner = "0x" + String(repeating: "22", count: 20)
    private let router = "0xb30ec53f98ff5947ede720d32ac2da7e52a5f56b"
    private let vault = "0x" + String(repeating: "11", count: 20)
    private func vector(_ name: String) throws -> SolanaJSON {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ThorchainDeposits", withExtension: "json", subdirectory: "Fixtures"))
        let rows = try JSONDecoder().decode(SolanaJSON.self, from: Data(contentsOf: url))
        return try XCTUnwrap(rows.array?.first { $0["name"].string == name })
    }
    private func request(_ vector: SolanaJSON, data: String? = nil, value: String? = nil, chain: UInt64? = nil, recipient: String? = nil) throws -> WalletConnectEVMRequest {
        let fields = ["from": owner, "to": recipient ?? router, "value": try EVMSendAmount.hex(value ?? vector["value"].string!), "data": data ?? vector["data"].string!]
        return try .init(params: JSONEncoder().encode([fields]), account: owner, chainID: chain ?? UInt64(vector["chain"].integer!))
    }
    func testIndependentABIForEachEVMChainAndNativeValue() throws {
        for name in ["bsc-usdt-rune", "eth-native-rune", "avax-usdc-rune", "base-native-rune", "bsc-usdt-eth-usdc"] {
            let v = try vector(name), d = try XCTUnwrap(ThorchainEVMDeposit(request(v)))
            XCTAssertEqual(d.vault, vault)
            XCTAssertEqual(d.amount, v["value"].string == "0" ? v["amount"].string : v["value"].string)
            XCTAssertEqual(d.resolvedMemo()!.destination, name.hasSuffix("eth-usdc") ? owner : "thor172egzpvhpe4pgd69ql4fjr6sjrlrftkgat79m2")
            XCTAssertEqual(d.resolvedMemo()!.networkID, name.hasSuffix("eth-usdc") ? "ethereum" : "thorchain")
            XCTAssertEqual(d.resolvedMemo()!.symbol, name.hasSuffix("eth-usdc") ? "USDC" : "RUNE")
            XCTAssertEqual(try d.protocolAmount(decimals: name.hasPrefix("avax") ? 6 : 18), name.contains("native") ? "1000000" : "2000000000")
        }
    }
    func testNativeBNBWithShortTokenMemoIsRecognized() throws {
        XCTAssertNotNil(ThorchainEVMDeposit(try request(vector("56-native-short-usdt"))))
    }
    func testCompleteReviewForEveryEVMSourceAndBothDepositForms() async throws {
        let bscUSDT = "BSC.USDT-0X55D398326F99059FF775485246999027B3197955"
        for (chain, code) in ThorchainSwapAsset.evmChains.sorted(by: { $0.key < $1.key }) {
            let nativeVector = try vector("\(chain)-native-short-usdt")
            let tokenVector = try vector("\(chain)-token-short-usdt")
            let tokenAsset = code + (chain == 56 ? ".USDT-" : ".USDC-") + tokenVector["token"].string!.uppercased()
            let nativeAsset = code + "." + (chain == 56 ? "BNB" : chain == 43114 ? "AVAX" : chain == 137 ? "POL" : "ETH")
            let poolRows: SolanaJSON = .array(Set([nativeAsset, tokenAsset, bscUSDT]).map {
                .object(["asset": .string($0), "status": .string("Available"), "asset_tor_price": .string("100000000")])
            })
            let rows: SolanaJSON = .array([.object(["chain": .string(code), "router": .string(router), "address": .string(vault),
                "halted": .bool(false), "global_trading_paused": .bool(false), "chain_trading_paused": .bool(false)])])
            let transport = ThorchainReviewTransport(inbounds: rows, pools: poolRows)
            let client = ThorchainClient(transport: transport)
            for mode in ["native", "token", "direct"] {
                let v = mode == "token" ? tokenVector : nativeVector
                let data = mode == "direct" ? "0x" + TronSendCrypto.hex(Data(v["memo"].string!.utf8)) : v["data"].string!
                let input = try request(v, data: data, recipient: mode == "direct" ? vault : router)
                let deposit = try XCTUnwrap(ThorchainEVMDeposit(input))
                let decimals = mode == "token" && chain != 56 ? 6 : 18
                let value = try await client.walletConnectEVMSwapReview(deposit, decimals: decimals)
                let review = try XCTUnwrap(value, "\(chain):\(mode)")
                XCTAssertEqual(review.inputAsset.id, mode == "token" ? tokenAsset : nativeAsset)
                XCTAssertEqual(review.quote.memo.asset, bscUSDT)
                XCTAssertEqual(review.quote.memo.destination, owner)
                XCTAssertEqual(review.quote.memo.minimum, "100")
                XCTAssertEqual(review.quote.memo.rawValue, v["memo"].string)
                XCTAssertEqual(review.deposit.amount, mode == "token" ? v["amount"].string : v["value"].string)
                XCTAssertEqual(review.quote.input, mode == "token" ? "2000000000" : "1000000")
                XCTAssertEqual(review.quote.expectedOutput, "675096000")
                XCTAssertEqual(review.quote.totalFee, "24000000")
                XCTAssertEqual(review.quote.priceImpactBPS, 19)
                XCTAssertEqual(review.quote.totalSeconds, 60)
                XCTAssertEqual(review.quote.inputPriceUSD, "1"); XCTAssertEqual(review.quote.outputPriceUSD, "1")
                XCTAssertEqual(input.call.hex, data.lowercased())
                XCTAssertEqual(deposit.expiry == nil, mode == "direct")
                let queries = await transport.queries
                let query = try XCTUnwrap(queries.last)
                XCTAssertEqual(query["from_asset"], review.inputAsset.id)
                XCTAssertEqual(query["to_asset"], bscUSDT)
                XCTAssertEqual(query["amount"], review.quote.input)
                XCTAssertEqual(query["destination"], owner)
            }
        }
    }
    func testUnresolvedOrExtendedMemosNeverBecomeFullReviews() async throws {
        let v = try vector("56-native-short-usdt")
        let other = "BSC.USDT-0X1111111111111111111111111111111111117955"
        let poolRows = try XCTUnwrap(pools.array) + [.object(["asset": .string("BSC.BNB"), "status": .string("Available")]),
            .object(["asset": .string(other), "status": .string("Available")])]
        let transport = ThorchainReviewTransport(inbounds: inbound(), pools: .array(poolRows))
        let client = ThorchainClient(transport: transport)
        for text in [v["memo"].string!, "=:BSC.USDT-7954:\(owner):100", "=:BSC.USDT:\(owner):100/1/1:affiliate:10:extra"] {
            let deposit = try XCTUnwrap(ThorchainEVMDeposit(request(v, data: "0x" + TronSendCrypto.hex(Data(text.utf8)), recipient: vault)))
            let review = try await client.walletConnectEVMSwapReview(deposit, decimals: 18)
            XCTAssertNil(review)
        }
        let queries = await transport.queries
        XCTAssertTrue(queries.isEmpty)
    }
    func testDirectTransferMustTargetVerifiedActiveVault() throws {
        let v = try vector("56-native-short-usdt"), data = "0x" + TronSendCrypto.hex(Data(v["memo"].string!.utf8))
        let nativePools: SolanaJSON = .array([.object(["asset": .string("BSC.BNB"), "status": .string("Available")])])
        let transfer = try XCTUnwrap(ThorchainEVMDeposit(request(v, data: data, recipient: owner)))
        XCTAssertNil(try ThorchainClient.swapInput(transfer, inbounds: inbound(), pools: nativePools))
        let deposit = try XCTUnwrap(ThorchainEVMDeposit(request(v, data: data, recipient: vault)))
        XCTAssertEqual(try ThorchainClient.swapInput(deposit, inbounds: inbound(), pools: nativePools)?.id, "BSC.BNB")
        XCTAssertThrowsError(try ThorchainClient.swapInput(deposit, inbounds: inbound(halted: true), pools: nativePools))
        XCTAssertNil(ThorchainEVMDeposit(try request(v, data: data, value: "0", recipient: vault)))
        XCTAssertNil(ThorchainEVMDeposit(try request(v, data: data + "00", recipient: vault)))
    }
    func testMalformedOrConcealedPaymentsNeverGetSwapTemplate() throws {
        let v = try vector("bsc-usdt-rune"), data = v["data"].string!
        let badOffset = String(data.prefix(202)) + String(repeating: "0", count: 63) + "1" + String(data.dropFirst(266))
        let invalid: [String] = [String(data.dropLast(2)), data + "00", "0xdeadbeef" + String(data.dropFirst(10)), badOffset, String(data.dropLast(2)) + "01"]
        for modified in invalid {
            XCTAssertNil(ThorchainEVMDeposit(try request(v, data: modified)))
        }
        XCTAssertNil(ThorchainEVMDeposit(try request(v, value: "1")))
        XCTAssertNil(ThorchainEVMDeposit(try request(v, chain: 42161)))
        let native = try vector("eth-native-rune")
        XCTAssertNil(ThorchainEVMDeposit(try request(native, value: "0")))
    }
    private func inbound(address: String? = nil, halted: Bool = false) -> SolanaJSON {
        .array([.object(["chain": .string("BSC"), "router": .string(router), "address": .string(address ?? vault),
            "halted": .bool(halted), "global_trading_paused": .bool(false), "chain_trading_paused": .bool(false)])])
    }
    private var pools: SolanaJSON {
        .array([.object(["asset": .string("BSC.USDT-0X55D398326F99059FF775485246999027B3197955"), "status": .string("Available"),
                         "asset_tor_price": .string("100000000")])])
    }
    func testRouterVaultChainAndPoolIdentityMustMatch() throws {
        let v = try vector("bsc-usdt-rune"), d = try XCTUnwrap(ThorchainEVMDeposit(request(v)))
        XCTAssertEqual(try ThorchainClient.swapInput(d, inbounds: inbound(), pools: pools)?.symbol, "USDT")
        XCTAssertThrowsError(try ThorchainClient.swapInput(d, inbounds: inbound(address: owner), pools: pools))
        XCTAssertThrowsError(try ThorchainClient.swapInput(d, inbounds: inbound(halted: true), pools: pools))
        XCTAssertThrowsError(try ThorchainClient.swapInput(d, inbounds: inbound(), pools: .array([])))
        let haltedPool: SolanaJSON = .object(["asset": .string("BSC.USDT-0X55D398326F99059FF775485246999027B3197955"),
            "status": .string("Available"), "trading_halted": .string("false")])
        XCTAssertThrowsError(try ThorchainClient.swapInput(d, inbounds: inbound(), pools: .array([haltedPool])))
        let spoof = try XCTUnwrap(ThorchainEVMDeposit(request(v, recipient: owner)))
        XCTAssertNil(try ThorchainClient.swapInput(spoof, inbounds: inbound(), pools: pools))
        let active: SolanaJSON = .array([.object(["status": .string("ActiveVault"), "addresses": .array([.object(["chain": .string("BSC"), "address": .string(vault)])]),
            "routers": .array([.object(["chain": .string("BSC"), "router": .string(router)])])])])
        XCTAssertNotNil(try ThorchainClient.swapInput(d, inbounds: inbound(address: owner), pools: pools, vaults: active))
        XCTAssertEqual(ThorchainClient.swapPrice(d.resolvedMemo()!.asset, pools: pools, stats: .object(["runePriceUSD": .string("0.62")])), "0.62")
    }
    func testRuneQuoteKeepsSignedMinimumAndOptionalMetadata() throws {
        let memo = try XCTUnwrap(ThorchainEVMDeposit(request(vector("bsc-usdt-rune")))?.resolvedMemo())
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json: SolanaJSON = .object(["memo": .string("=:r:\(memo.destination):0/1/1"), "expiry": .number("1700000600"),
            "expected_amount_out": .string("3229050000"), "fees": .object(["asset": .string("THOR.RUNE"), "outbound": .string("0"),
            "liquidity": .string("3200000"), "affiliate": .string("0"), "slippage_bps": .number("9")]), "total_swap_seconds": .number("60")])
        let quote = try ThorchainSwapQuote.decode(json, memo: memo, input: "2000000000", now: now, inputPriceUSD: "1", outputPriceUSD: "0.62")
        XCTAssertEqual(quote.memo.minimum, "3199660000")
        XCTAssertEqual(quote.expectedOutput, "3229050000")
        XCTAssertEqual(quote.priceImpactBPS, 9); XCTAssertEqual(quote.totalSeconds, 60)
        XCTAssertEqual(quote.totalFee, "3200000")
        guard case .object(var fields) = json else { return XCTFail() }
        fields.removeValue(forKey: "total_swap_seconds")
        XCTAssertNil(try ThorchainSwapQuote.decode(.object(fields), memo: memo, input: "2000000000", now: now).totalSeconds)
        fields["total_swap_seconds"] = .number("-1")
        XCTAssertThrowsError(try ThorchainSwapQuote.decode(.object(fields), memo: memo, input: "2000000000", now: now))
    }
    func testQuoteDefaultStreamingParametersAndExactFeeSum() throws {
        let memo = try XCTUnwrap(ThorchainSwapMemo("=:r:thor172egzpvhpe4pgd69ql4fjr6sjrlrftkgat79m2:0"))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let huge = String(repeating: "9", count: 45)
        let json: SolanaJSON = .object(["memo": .string("=:r:\(memo.destination):0/0/0"), "expiry": .number("1700000600"),
            "expected_amount_out": .string("123"), "fees": .object(["asset": .string("THOR.RUNE"), "outbound": .string(huge),
            "liquidity": .string("1"), "affiliate": .string("0")])])
        let quote = try ThorchainSwapQuote.decode(json, memo: memo, input: "123", now: now)
        XCTAssertEqual(quote.totalFee, "1" + String(repeating: "0", count: 45))
        XCTAssertNil(quote.totalSeconds); XCTAssertNil(quote.priceImpactBPS)
    }
    func testOptInLiveBSCQuoteUsesProductionDecoderAndClient() async throws {
        guard ProcessInfo.processInfo.environment["OATH_THORCHAIN_WC_LIVE_QUOTE"] == "1" else { throw XCTSkip("Read-only mainnet quote check") }
        let client = ThorchainClient()
        let rows = try await client.read(ThorchainClient.node, path: "thorchain/inbound_addresses")
        let inbound = try XCTUnwrap(rows.array?.first { $0["chain"].string == "BSC" })
        let v = try vector("bsc-live-rune"), data = try XCTUnwrap(v["data"].string)
        let word = String(repeating: "0", count: 24) + String(try XCTUnwrap(inbound["address"].string).dropFirst(2))
        let actual = String(data.prefix(10)) + word + data.dropFirst(74)
        let deposit = try XCTUnwrap(ThorchainEVMDeposit(request(v, data: actual, recipient: inbound["router"].string)))
        let value = try await client.walletConnectEVMSwapReview(deposit, decimals: 18)
        let review = try XCTUnwrap(value)
        XCTAssertEqual(review.inputAsset.reference, deposit.reference)
        XCTAssertEqual(review.quote.memo.minimum, "0")
        XCTAssertEqual(review.quote.input, "2000000000")
        XCTAssertGreaterThan(review.quote.expires, .now)
        XCTAssertNotNil(review.quote.inputPriceUSD); XCTAssertNotNil(review.quote.outputPriceUSD)
        XCTAssertNotNil(review.quote.priceImpactBPS)
    }
    func testOptInLiveNativeToTokenQuotesAcrossActiveEVMChains() async throws {
        guard ProcessInfo.processInfo.environment["OATH_THORCHAIN_WC_LIVE_QUOTE"] == "1" else { throw XCTSkip("Read-only mainnet quotes; no signing or broadcast") }
        let client = ThorchainClient()
        let rows = try await client.read(ThorchainClient.node, path: "thorchain/inbound_addresses")
        for (chain, code) in [(UInt64(1), "ETH"), (56, "BSC"), (43114, "AVAX"), (8453, "BASE")] {
            let inbound = try XCTUnwrap(rows.array?.first { $0["chain"].string == code })
            let v = try vector("\(chain)-native-short-usdt")
            let data = try XCTUnwrap(v["data"].string)
            let word = String(repeating: "0", count: 24) + String(try XCTUnwrap(inbound["address"].string).dropFirst(2))
            let actual = String(data.prefix(10)) + word + data.dropFirst(74)
            // One AVAX avoids the minimum-deposit threshold of a 0.01 AVAX quote.
            let input = try request(v, data: actual, value: chain == 43114 ? "1000000000000000000" : nil, recipient: inbound["router"].string)
            let deposit = try XCTUnwrap(ThorchainEVMDeposit(input))
            let result = try await client.walletConnectEVMSwapReview(deposit, decimals: 18)
            let review = try XCTUnwrap(result, code)
            XCTAssertEqual(review.inputAsset.networkID, EVMSendNetwork.allCases.first { $0.chainID == chain }?.rawValue)
            XCTAssertEqual(review.quote.memo.asset, "BSC.USDT-0X55D398326F99059FF775485246999027B3197955")
            XCTAssertEqual(review.quote.memo.rawValue, v["memo"].string)
            XCTAssertEqual(review.quote.memo.minimum, "100")
            XCTAssertEqual(review.quote.memo.destination, owner)
            XCTAssertGreaterThan(review.quote.expires, .now)
            XCTAssertNotNil(review.quote.inputPriceUSD); XCTAssertNotNil(review.quote.outputPriceUSD)
            XCTAssertNotNil(review.quote.priceImpactBPS)
            // THORNode omits total_swap_seconds for some immediate inbound routes.
            // The review must retain that absence, rather than invent a duration.
            if let seconds = review.quote.totalSeconds { XCTAssertLessThanOrEqual(seconds, 31_536_000) }
            XCTAssertNotEqual(review.quote.expectedOutput, "0")
        }
    }
}

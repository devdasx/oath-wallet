import XCTest
@testable import OathAnkr

final class ThorchainSwapReviewTests: XCTestCase {
    let destination = "0x2222222222222222222222222222222222222222"
    let bscUSDT = "BSC.USDT-0X55D398326F99059FF775485246999027B3197955"
    func testEverySupportedOutputNetworkAndEVMTokenIdentity() throws {
        let natives = ["THOR.RUNE": "thorchain", "BTC.BTC": "bitcoin", "ETH.ETH": "ethereum", "BSC.BNB": "bnb",
            "AVAX.AVAX": "avalanche", "BASE.ETH": "base", "POL.POL": "polygon", "LTC.LTC": "litecoin",
            "BCH.BCH": "bitcoincash", "DOGE.DOGE": "dogecoin", "TRON.TRX": "tron", "XRP.XRP": "xrpl", "SOL.SOL": "solana"]
        for (asset, network) in natives {
            let memo = try XCTUnwrap(ThorchainSwapMemo("=:\(asset):\(destination):123e4/1/1"))
            XCTAssertEqual(memo.asset, asset); XCTAssertEqual(memo.networkID, network)
            XCTAssertEqual(memo.minimum, "1230000")
        }
        XCTAssertEqual(ThorchainSwapMemo("=:p:\(destination):0")?.networkID, "polygon")
        for (prefix, network) in ["ETH": "ethereum", "BSC": "bnb", "AVAX": "avalanche", "BASE": "base", "POL": "polygon"] {
            let token = prefix + ".USDC-0X" + String(repeating: "12", count: 20)
            for alias in [prefix + ".USDC", prefix + ".USDC-1212", token] {
                let memo = try XCTUnwrap(ThorchainSwapMemo("=:\(alias):\(destination):100", poolAssets: [token]))
                XCTAssertEqual(memo.asset, token); XCTAssertEqual(memo.networkID, network)
                XCTAssertEqual(memo.symbol, "USDC")
            }
        }
    }
    func testBSCQuoteAcceptsTHORNodesAbbreviatedMemo() throws {
        let memo = try XCTUnwrap(ThorchainSwapMemo("=:\(bscUSDT):\(destination):100/1/1"))
        let json: SolanaJSON = .object(["memo": .string("=:BSC.USDT:\(destination):0/1/1"),
            "expiry": .number("1700000600"), "expected_amount_out": .string("150"),
            "fees": .object(["asset": .string(bscUSDT), "outbound": .string("10"), "liquidity": .string("5"), "affiliate": .string("0")])])
        let quote = try ThorchainSwapQuote.decode(json, memo: memo, input: "1250000000", now: Date(timeIntervalSince1970: 1_700_000_000), poolAssets: [bscUSDT])
        XCTAssertEqual(quote.memo.asset, bscUSDT)
        XCTAssertEqual(quote.memo.minimum, "100")
    }
    func testShortTokenMemoResolutionNeverGuessesNetworkOrContract() throws {
        for alias in ["BSC.USDT", "BSC.USDT-7955", "BSC.USDT-999027B3197955", bscUSDT] {
            let raw = "=:\(alias):\(destination):123e4/1/1:affiliate:10"
            let memo = try XCTUnwrap(ThorchainSwapMemo(raw, poolAssets: [bscUSDT]))
            XCTAssertEqual(memo.asset, bscUSDT); XCTAssertEqual(memo.rawValue, raw)
            XCTAssertEqual(memo.minimum, "1230000"); XCTAssertEqual(memo.affiliateBPS, 10)
        }
        for alias in ["ETH.USDT", "BSC.USDC", "BSC.USDT-7954", "BSC.USDT-Z", "BSC.USDT--", "BSC/USDT", "BSC~USDT"] {
            XCTAssertNil(ThorchainSwapMemo("=:\(alias):\(destination):1", poolAssets: [bscUSDT]), alias)
        }
        let other = "BSC.USDT-0X1111111111111111111111111111111111117955"
        XCTAssertNil(ThorchainSwapMemo("=:BSC.USDT:\(destination):1", poolAssets: [bscUSDT, other]))
        XCTAssertNil(ThorchainSwapMemo("=:BSC.USDT-7955:\(destination):1", poolAssets: [bscUSDT, other]))
        XCTAssertNil(ThorchainSwapMemo("=:BSC.USDT:\(destination):1"))
    }
    func testAbbreviatedQuoteStillBindsExactAssetAndDestination() throws {
        let memo = try XCTUnwrap(ThorchainSwapMemo("=:\(bscUSDT):\(destination):100/1/1:affiliate:10"))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fee: SolanaJSON = .object(["asset": .string(bscUSDT), "outbound": .string("10"), "liquidity": .string("5"), "affiliate": .string("1")])
        let correct = "=:BSC.USDT:\(destination):0/1/1:affiliate:10"
        for echo in ["=:ETH.USDT:\(destination):0/1/1:affiliate:10", "=:BSC.USDT-7954:\(destination):0/1/1:affiliate:10",
                     correct.replacingOccurrences(of: destination, with: "0x3333333333333333333333333333333333333333"),
                     correct.replacingOccurrences(of: "affiliate:10", with: "other:10"), correct.replacingOccurrences(of: "/1/1", with: "/0/0")] {
            let json: SolanaJSON = .object(["memo": .string(echo), "expiry": .number("1700000600"), "expected_amount_out": .string("150"), "fees": fee])
            XCTAssertThrowsError(try ThorchainSwapQuote.decode(json, memo: memo, input: "1000", now: now, poolAssets: [bscUSDT]))
        }
    }
    func testMemoDecodingPreservesExactLimitAndRejectsUnsupportedVariants() throws {
        let memo = try XCTUnwrap(ThorchainSwapMemo("=:e:\(destination):123e4/1/1:affiliate:10"))
        XCTAssertEqual(memo.asset, "ETH.ETH"); XCTAssertEqual(memo.minimum, "1230000")
        XCTAssertEqual(memo.destination, destination); XCTAssertEqual(memo.affiliateBPS, 10)
        XCTAssertEqual(memo.interval, 1); XCTAssertEqual(memo.quantity, 1)
        XCTAssertEqual(ThorchainSwapMemo("SWAP:ETH.ETH:\(destination)")?.minimum, "0")
        XCTAssertNil(ThorchainSwapMemo("=<:ETH.ETH:\(destination):123"))
        for value in ["=:ETH.USDC:\(destination)", "=:ETH~ETH:\(destination)", "=:BTC-BTC:\(destination)",
                      "=:e:\(destination):1/1/1:affiliate:1001", "=:e:\(destination):1/1/1::10",
                      "=:e:\(destination):1/1/1:affiliate:1:extra", "=:e:\(destination)/refund:1", "=:e:\(destination):1e99",
                      "=:e:\(destination):1/-1/1", "=:e:\(destination):1/1/43201", "=:e:\(destination):1e-2"] {
            XCTAssertNil(ThorchainSwapMemo(value), value)
        }
    }
    func testQuoteBindingAndExpiryRejectMisroutedOrBelowMinimumOutput() throws {
        let memo = try XCTUnwrap(ThorchainSwapMemo("=:ETH.ETH:\(destination):100/1/1"))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var json: SolanaJSON = .object(["memo": .string("=:e:\(destination):0/1/1"), "expiry": .number("1700000600"),
            "expected_amount_out": .string("150"), "fees": .object(["asset": .string("ETH.ETH"), "outbound": .string("10"), "liquidity": .string("5"), "affiliate": .string("0")])])
        let quote = try ThorchainSwapQuote.decode(json, memo: memo, input: "1250000000", now: now)
        XCTAssertEqual(quote.memo.minimum, "100") // never adopt provider's suggested minimum
        XCTAssertEqual(quote.expectedOutput, "150"); XCTAssertEqual(quote.outboundFee, "10")
        guard case .object(let original) = json else { return XCTFail() }
        for (key, bad): (String, SolanaJSON) in [
            ("memo", .string("=:e:0x3333333333333333333333333333333333333333:0/1/1")),
            ("memo", .string("=:e:\(destination):0/0/0")),
            ("memo", .string("=:e:\(destination):0/1/1:other:10")),
            ("expected_amount_out", .string("99")), ("expiry", .number("1700000000")),
            ("expiry", .number("1700009999")), ("fees", .object(["asset": .string("BTC.BTC")]))] {
            var changed = original; changed[key] = bad; json = .object(changed)
            XCTAssertThrowsError(try ThorchainSwapQuote.decode(json, memo: memo, input: "1250000000", now: now))
        }
    }
    func testOptInPublicQuoteUsesProductionClientWithoutSigningOrBroadcast() async throws {
        guard ProcessInfo.processInfo.environment["OATH_THORCHAIN_WC_LIVE_QUOTE"] == "1" else {
            throw XCTSkip("Explicit read-only public-network quote check")
        }
        let key = try ThorchainSendCrypto.publicKey(privateKey: Data(repeating: 1, count: 32))
        let owner = try ThorchainSendCrypto.address(publicKey: key, network: .mainnet)
        for asset in ["ETH.ETH", bscUSDT, "BSC.USDT", "BSC.USDT-7955"] {
        let doc: SolanaJSON = .object(["chain_id": .string("thorchain-1"), "account_number": .string("0"), "sequence": .string("0"),
            "fee": .object(["gas": .string("200000"), "amount": .array([])]), "memo": .string(""),
            "msgs": .array([.object(["type": .string("thorchain/MsgDeposit"), "value": .object(["signer": .string(owner),
                "memo": .string("=:\(asset):\(destination):0/1/1"),
                "coins": .array([.object(["asset": .string("THOR.RUNE"), "amount": .string("1250000000")])])])])])])
        let request = try ThorchainWalletConnectRequest(method: "cosmos_signAmino",
            params: .object(["signerAddress": .string(owner), "signDoc": doc]), sender: owner, publicKey: key)
        let value = try await ThorchainClient().walletConnectSwapQuote(request)
        let quote = try XCTUnwrap(value)
        XCTAssertEqual(quote.memo.asset, asset == "ETH.ETH" ? asset : bscUSDT); XCTAssertEqual(quote.memo.destination, destination)
        XCTAssertEqual(quote.memo.minimum, "0"); XCTAssertEqual(quote.input, "1250000000")
        XCTAssertNotEqual(quote.expectedOutput, "0"); XCTAssertGreaterThan(quote.expires, .now)
        XCTAssertEqual(quote.memo.rawValue, request.memo)
        let resolved = try await ThorchainClient().resolvedSwapMemo(request.memo)
        XCTAssertEqual(resolved, quote.memo)
        }
    }
}

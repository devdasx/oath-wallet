import XCTest
@testable import OathAnkr

final class ThorchainSwapReviewTests: XCTestCase {
    let destination = "0x2222222222222222222222222222222222222222"
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
        let doc: SolanaJSON = .object(["chain_id": .string("thorchain-1"), "account_number": .string("0"), "sequence": .string("0"),
            "fee": .object(["gas": .string("200000"), "amount": .array([])]), "memo": .string(""),
            "msgs": .array([.object(["type": .string("thorchain/MsgDeposit"), "value": .object(["signer": .string(owner),
                "memo": .string("=:ETH.ETH:\(destination):0/1/1"),
                "coins": .array([.object(["asset": .string("THOR.RUNE"), "amount": .string("1250000000")])])])])])])
        let request = try ThorchainWalletConnectRequest(method: "cosmos_signAmino",
            params: .object(["signerAddress": .string(owner), "signDoc": doc]), sender: owner, publicKey: key)
        let value = try await ThorchainClient().walletConnectSwapQuote(request)
        let quote = try XCTUnwrap(value)
        XCTAssertEqual(quote.memo.asset, "ETH.ETH"); XCTAssertEqual(quote.memo.destination, destination)
        XCTAssertEqual(quote.memo.minimum, "0"); XCTAssertEqual(quote.input, "1250000000")
        XCTAssertNotEqual(quote.expectedOutput, "0"); XCTAssertGreaterThan(quote.expires, .now)
    }
}

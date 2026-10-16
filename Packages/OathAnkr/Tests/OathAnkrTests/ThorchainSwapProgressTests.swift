import XCTest
@testable import OathAnkr

final class ThorchainSwapProgressTests: XCTestCase {
    let txHash = String(repeating: "AB", count: 32)
    let destination = "0x2222222222222222222222222222222222222222"
    func fixture(deposit: Bool = true, swapped: Bool = false, signed: Bool = false) throws -> SolanaJSON {
        let key = try ThorchainSendCrypto.publicKey(privateKey: Data(repeating: 1, count: 32))
        let sender = try ThorchainSendCrypto.address(publicKey: key, network: .mainnet)
        return .object(["tx": .object(["id": .string(txHash), "chain": .string("THOR"), "from_address": .string(sender),
            "memo": .string("=:ETH.ETH:\(destination):100/1/1"),
            "coins": .array([.object(["asset": .string("THOR.RUNE"), "amount": .string("250000000")])])]),
            "stages": .object(["inbound_finalised": .object(["completed": .bool(deposit)]),
                "swap_finalised": .object(["completed": .bool(swapped)]), "outbound_signed": .object(["completed": .bool(signed)])]),
            "planned_out_txs": .array([]), "out_txs": .array([])])
    }
    func outbound(to: String? = nil, asset: String = "ETH.ETH", memo: String? = nil) -> SolanaJSON {
        .object(["id": .string(String(repeating: "CD", count: 32)), "chain": .string("ETH"),
            "to_address": .string(to ?? destination), "memo": .string(memo ?? "OUT:" + txHash),
            "coins": .array([.object(["asset": .string(asset), "amount": .string("120")])])])
    }
    func with(_ root: SolanaJSON, _ key: String, _ value: SolanaJSON) -> SolanaJSON {
        guard case .object(var fields) = root else { return .null }; fields[key] = value; return .object(fields)
    }
    func testDepositAndOutboundSigningNeverInventDelivery() throws {
        for (deposit, swap, signed) in [(false,false,false), (true,false,false), (true,true,false), (true,true,true)] {
            let result = try XCTUnwrap(ThorchainSwapProgress.decode(fixture(deposit: deposit, swapped: swap, signed: signed), hash: txHash))
            XCTAssertEqual(result.depositConfirmed, deposit); XCTAssertEqual(result.swapFinalised, swap)
            XCTAssertEqual(result.outboundSigned, signed); XCTAssertFalse(result.isFinished); XCTAssertNil(result.outboundHash)
        }
    }
    func testObservedDestinationMustMatchAssetAddressAndInboundMemo() throws {
        let root = try fixture(swapped: true, signed: true)
        let result = try XCTUnwrap(ThorchainSwapProgress.decode(with(root,"out_txs",.array([outbound()])), hash: txHash))
        XCTAssertTrue(result.isFinished); XCTAssertNotNil(result.outboundHash)
        for out in [outbound(to: "0x3333333333333333333333333333333333333333"), outbound(asset: "BTC.BTC"), outbound(memo: "OUT:" + String(repeating: "EF", count: 32)),
                    with(outbound(), "id", .string(String(repeating: "0", count: 64)))] {
            XCTAssertNil(try ThorchainSwapProgress.decode(with(root, "out_txs", .array([out])), hash: txHash)?.outboundHash)
        }
        XCTAssertThrowsError(try ThorchainSwapProgress.decode(with(fixture(deposit: false), "out_txs", .array([outbound()])), hash: txHash))
    }
    func testRefundIsSeparateFromSuccessfulDestinationDelivery() throws {
        let root = try fixture(swapped: false)
        let sender = try XCTUnwrap(root["tx"]["from_address"].string)
        let refund: SolanaJSON = .object(["id": .string(String(repeating: "EF", count: 32)), "chain": .string("THOR"),
            "to_address": .string(sender), "memo": .string("REFUND:" + txHash),
            "coins": .array([.object(["asset": .string("THOR.RUNE"), "amount": .string("249000000")])])])
        let result = try XCTUnwrap(ThorchainSwapProgress.decode(with(root, "out_txs", .array([refund])), hash: txHash))
        XCTAssertNotNil(result.refundHash); XCTAssertNil(result.outboundHash); XCTAssertTrue(result.isFinished)
        let internalRefund = try XCTUnwrap(ThorchainSwapProgress.decode(with(root, "out_txs", .array([with(refund, "id", .string(String(repeating: "0", count: 64)))])), hash: txHash))
        XCTAssertTrue(internalRefund.refundObserved); XCTAssertTrue(internalRefund.isFinished)
        XCTAssertNil(internalRefund.refundHash); XCTAssertNil(internalRefund.outboundHash)
    }
    func testMissingUnsupportedMismatchedAndMalformedDataStayUnknown() throws {
        XCTAssertNil(try ThorchainSwapProgress.decode(.object([:]), hash: txHash))
        let root = try fixture()
        XCTAssertThrowsError(try ThorchainSwapProgress.decode(root, hash: String(repeating: "EF", count: 32)))
        XCTAssertThrowsError(try ThorchainSwapProgress.decode(root, hash: "../tx"))
        XCTAssertThrowsError(try ThorchainSwapProgress.decode(with(root,"stages",.object(["inbound_finalised": .object(["completed": .string("true")])])), hash: txHash))
        XCTAssertNil(try ThorchainSwapProgress.decode(with(root,"tx",with(root["tx"],"memo",.string("RESERVE"))), hash: txHash))
    }
    func testOptInPublicRUNEToLitecoinProgressUsesProductionClient() async throws {
        guard ProcessInfo.processInfo.environment["OATH_THORCHAIN_WC_LIVE_PROGRESS"] == "1" else {
            throw XCTSkip("Read-only historical public swap; no wallet or transaction submission")
        }
        let result = try await ThorchainClient().swapProgress(hash: "CB6EB0DD1B33B591D383FD56CCD4A5D2815C1C768E2EBB802681A8A6211C3560")
        let observed = try XCTUnwrap(result)
        XCTAssertTrue(observed.depositConfirmed); XCTAssertTrue(observed.swapFinalised); XCTAssertTrue(observed.isFinished)
        XCTAssertEqual(observed.memo.asset, "LTC.LTC")
        XCTAssertEqual(observed.memo.destination, "ltc1q6zvz3d5tnaqd6exg4vljvtn8lcg4qfqsu4cc4h")
        XCTAssertEqual(observed.outboundHash, "EE169F0C6C8669455328FBC948C6DA9840968670A30AB5AF2F12EE6FE691ECBD")
        XCTAssertFalse(observed.refundObserved)
    }

}

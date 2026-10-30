import XCTest
@testable import OathAnkr

final class EVMHistoryPoolTests: XCTestCase {
    func fixture() throws -> EVMHistoryEvidence { try EVMHistorySwapTests().fixture("sepolia-unknown-router-native-output") }
    func classify(_ e: EVMHistoryEvidence) throws -> EVMHistorySwap? {
        try EVMHistorySwap.classify(transaction: e.transaction, receipt: e.receipt, owner: e.transaction["from"].string!,
            chainID: 11155111, trace: e.trace, pools: e.pools ?? [])
    }
    func testRealUnknownRouterConnectsOwnerTokenToVerifiedPoolAndNativePayout() throws {
        let e = try fixture()
        XCTAssertNil(try classify(.init(transaction: e.transaction, receipt: e.receipt, trace: e.trace)))
        XCTAssertNil(try classify(.init(transaction: e.transaction, receipt: e.receipt, pools: e.pools)))
        let swap = try XCTUnwrap(classify(e))
        XCTAssertEqual(swap.input, "0x94a9d9ac8a22534e3faca9f4e7f2e2cf85d5e4c8")
        XCTAssertEqual(swap.output, "native")
        XCTAssertEqual(swap.spent, "4211528357")
        XCTAssertEqual(swap.received, "634216820978178")
    }
    func testWrongFactoryBlockChainOrPoolCannotAuthenticateUnknownRouter() throws {
        let e = try fixture(), p = try XCTUnwrap(e.pools?.first)
        for bad in [
            EVMHistoryPool(chainID: 1, blockHash: p.blockHash, address: p.address, factory: p.factory, token0: p.token0, token1: p.token1, kind: p.kind, registeredPool: p.registeredPool),
            EVMHistoryPool(chainID: p.chainID, blockHash: "0x00", address: p.address, factory: p.factory, token0: p.token0, token1: p.token1, kind: p.kind, registeredPool: p.registeredPool),
            EVMHistoryPool(chainID: p.chainID, blockHash: p.blockHash, address: p.address, factory: p.address, token0: p.token0, token1: p.token1, kind: p.kind, registeredPool: p.registeredPool),
            EVMHistoryPool(chainID: p.chainID, blockHash: p.blockHash, address: p.address, factory: p.factory, token0: p.token0, token1: p.token1, kind: p.kind, registeredPool: p.factory)
        ] {
            XCTAssertNil(try classify(.init(transaction: e.transaction, receipt: e.receipt, trace: e.trace, pools: [bad])))
        }
    }
    func testDisconnectedTransferAndRevertedPayoutAreNotSwaps() throws {
        let e = try fixture(), helper = EVMHistorySwapTests(), owner = e.transaction["from"].string!
        let logs = e.receipt["logs"].array!.map { log -> SolanaJSON in
            guard log["topics"].array?.first?.string == EVMHistorySwap.transferTopic,
                  log["topics"].array?[1].string?.suffix(40) == owner.dropFirst(2),
                  log["address"].string != "0xfffffffffffffffffffffffffffffffffffffffe" else { return log }
            var topics = log["topics"].array!; topics[2] = .string("0x" + String(repeating: "1", count: 64))
            return helper.replacing(log, "topics", .array(topics))
        }
        XCTAssertNil(try classify(.init(transaction: e.transaction, receipt: helper.replacing(e.receipt, "logs", .array(logs)), trace: e.trace, pools: e.pools)))
        let root = helper.replacing(e.trace!.root, "error", .string("reverted"))
        let trace = EVMHistoryTrace(chainID: 11155111, transactionHash: e.transaction["hash"].string!, blockHash: e.receipt["blockHash"].string!, root: root)
        XCTAssertNil(try classify(.init(transaction: e.transaction, receipt: e.receipt, trace: trace, pools: e.pools)))
    }
    func testPureWrapDoesNotBecomeSwapBecauseUnrelatedPoolTraded() throws {
        let e = try fixture(), owner = e.transaction["from"].string!
        let wrapped = WalletConnectSwapReview.wrappedNative[11155111]!
        let deposit: SolanaJSON = .object(["address": .string(wrapped),
            "topics": .array([.string(EVMHistorySwap.topic("Deposit(address,uint256)")), .string("0x" + String(repeating: "0", count: 24) + owner.dropFirst(2))]),
            "data": .string("0x" + String(repeating: "0", count: 63) + "a")])
        let logs = e.receipt["logs"].array!.filter { $0["topics"].array?.first?.string == EVMHistorySwap.v3Topic } + [deposit]
        let native = EVMHistoryTrace.Movement(transfers: [.init(from: owner, to: wrapped, amount: "10")], credits: "0", debits: "10")
        XCTAssertFalse(try EVMHistoryPool.connected(logs, pools: e.pools!, chainID: 11155111,
            block: e.receipt["blockHash"].string!, owner: owner, input: "native", output: wrapped, native: native))
    }

    func testPancakeV3ProtocolFeeEventUsesVerifiedFactoryAndStrictShape() throws {
        let owner = "0x" + String(repeating: "1", count: 40), pool = "0x" + String(repeating: "2", count: 40)
        let token0 = "0x" + String(repeating: "3", count: 40), token1 = "0x" + String(repeating: "4", count: 40)
        let block = "0x" + String(repeating: "5", count: 64)
        func padded(_ address: String) -> SolanaJSON { .string("0x" + String(repeating: "0", count: 24) + address.dropFirst(2)) }
        func transfer(_ token: String, _ from: String, _ to: String, _ amount: String) -> SolanaJSON {
            .object(["address": .string(token), "topics": .array([.string(EVMHistorySwap.transferTopic), padded(from), padded(to)]),
                "data": .string("0x" + String(repeating: "0", count: 64-amount.count) + amount)])
        }
        let proof = EVMHistoryPool(chainID: 56, blockHash: block, address: pool, factory: "0x0bfbcf9fa4f9c56b0f40a671ad40e0805a091865",
            token0: token0, token1: token1, kind: "v3", registeredPool: pool)
        let transfers = [transfer(token0, owner, pool, "64"), transfer(token1, pool, owner, "5a")]
        let data = "0x" + String(repeating: "0", count: 62) + "64" + String(repeating: "f", count: 62) + "a6" + String(repeating: "0", count: 320)
        let swap: SolanaJSON = .object(["address": .string(pool), "topics": .array([.string(EVMHistorySwap.pancakeV3Topic), padded(owner), padded(owner)]), "data": .string(data)])
        XCTAssertTrue(try EVMHistoryPool.connected(transfers + [swap], pools: [proof], chainID: 56, block: block, owner: owner, input: token0, output: token1))
        let truncated = EVMHistorySwapTests().replacing(swap, "data", .string(String(data.dropLast(128))))
        XCTAssertFalse(try EVMHistoryPool.connected(transfers + [truncated], pools: [proof], chainID: 56, block: block, owner: owner, input: token0, output: token1))
        XCTAssertFalse(try EVMHistoryPool.connected(transfers + [swap], pools: [proof], chainID: 1, block: block, owner: owner, input: token0, output: token1))
    }

}

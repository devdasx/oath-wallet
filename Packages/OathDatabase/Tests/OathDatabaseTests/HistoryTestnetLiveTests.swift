import Foundation
import XCTest
import OathAnkr
@testable import OathDatabase

/// Read-only public testnet receipts through the production RPC client and
/// SQLite projection. No application database or signing material is opened.
@MainActor final class HistoryTestnetLiveTests: XCTestCase {
    struct Sample: Decodable {
        let hash: String, owner: String, input: String, output: String, spent: String, received: String
    }
    func testSepoliaReceiptsBecomeOneSwapWithExactExecutedAmounts() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OATH_HISTORY_TESTNET_LIVE"] == "1",
              let config = env["OATH_HISTORY_TESTNET_RPC_PLIST"] else {
            throw XCTSkip("Explicit public testnet receipt validation required")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = env["OATH_HISTORY_TESTNET_CASES"] ?? root.appendingPathComponent("Tools/Fixtures/HistoryTestnet/sepolia-swaps.json").path
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        XCTAssertFalse(samples.isEmpty)
        XCTAssertLessThanOrEqual(samples.count, 12)
        let settings = try PropertyListDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: config)))
        let key = try XCTUnwrap(settings["AnkrAPIKey"])
        let endpoint = URL(string: "https://rpc.ankr.com/eth_sepolia")!.appendingPathComponent(key)
        let client = try EVMSendClient(network: .ethereumSepolia, endpoints: [endpoint])
        for sample in samples {
            let evidence = try await client.historyEvidence(hash: sample.hash)
            let swap = try XCTUnwrap(EVMHistorySwap.classify(transaction: evidence.transaction, receipt: evidence.receipt,
                owner: sample.owner, chainID: EVMSendNetwork.ethereumSepolia.chainID, trace: evidence.trace, pools: evidence.pools ?? []))
            XCTAssertEqual(swap.input, sample.input); XCTAssertEqual(swap.output, sample.output)
            XCTAssertEqual(swap.spent, sample.spent); XCTAssertEqual(swap.received, sample.received)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryTestnet-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
            try await db.seed(networks: [.init(id: "ethereumSepolia", name: "Sepolia", family: "evm", symbol: "ETH", decimals: 18, derivationPath: "test", logo: "", sortOrder: 0)], assets: [
                .init(id: "input", networkID: "ethereumSepolia", reference: sample.input, name: "Test Input", symbol: "IN", decimals: 18),
                .init(id: "output", networkID: "ethereumSepolia", reference: sample.output, name: "Test Output", symbol: "OUT", decimals: 18)])
            try await db.importWalletIfNeeded(.init(id: "test", name: "Public testnet", kind: "hd", vaultReference: "test-only", createdAt: 1), accounts: [
                .init(id: "a", walletID: "test", networkID: "ethereumSepolia", address: sample.owner, derivationPath: "test")])
            var batch = SyncBatch(cursor: .init(accountID: "a", stream: "fixture", cursor: "1", updatedAt: 100), expectedCursor: nil)
            batch.transactions = [.init(id: "tx", networkID: "ethereumSepolia", hash: sample.hash, state: "confirmed",
                blockHeight: Int64(try AnkrQuantity.decimal(evidence.receipt["blockNumber"].string!)),
                blockHash: evidence.receipt["blockHash"].string, timestamp: 100, updatedAt: 100)]
            batch.activity = [
                .init(id: "sent", walletID: "test", accountID: "a", networkID: "ethereumSepolia", transactionID: "tx", assetID: "input", direction: "outgoing", amountAtomic: sample.spent, counterparty: "", timestamp: 100),
                .init(id: "received", walletID: "test", accountID: "a", networkID: "ethereumSepolia", transactionID: "tx", assetID: "output", direction: "incoming", amountAtomic: sample.received, counterparty: "", timestamp: 100)]
            try await db.apply(batch)
            let candidates = try await db.swapHistoryCandidates(walletID: "test")
            try await db.saveSwapHistoryEvidence(evidence, candidate: XCTUnwrap(candidates.first))
            let rows = try await db.chainHistory(walletID: "test", currency: "USD")
            XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.entry.direction, "swap")
            XCTAssertEqual(rows.first?.entry.amountAtomic, sample.spent)
            XCTAssertEqual(rows.first?.receivedAtomic, sample.received)
            let detail = try await db.transactionDetails(accountID: "a", transactionID: "tx")
            XCTAssertEqual(detail?.swap?.id, rows.first?.id)
            try db.pool.close()
            print("HISTORY_TESTNET_VERIFIED chain=ethereumSepolia type=swap hash=\(sample.hash) rows=1 exact_amounts=true")
        }
    }
}

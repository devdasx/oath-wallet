import Foundation
import XCTest
@testable import OathDatabase
import OathAnkr

@MainActor final class EVMExecutionHistoryTests: XCTestCase {
    func evidence(_ directory: String, _ name: String) throws -> EVMHistoryEvidence {
        let packages = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(EVMHistoryEvidence.self, from: Data(contentsOf: packages.appendingPathComponent("OathAnkr/Tests/OathAnkrTests/Fixtures/\(directory)/\(name).json")))
    }
    func testNativeAndUnknownRouterSwapsPersistAsOneRowWithExactAssets() async throws {
        for (name, input, output, spent, received) in [
            ("sepolia-native-usdc", "native", "0x1c7d4b196cb0c7b01d743fbc6116a902379c7238", "5000000000000000000", "207044607346"),
            ("sepolia-unknown-router-native-output", "0x94a9d9ac8a22534e3faca9f4e7f2e2cf85d5e4c8", "native", "4211528357", "634216820978178")
        ] {
            let e = try evidence("HistorySwaps", name)
            let (db, folder) = try await seed(e, input: input, output: output, spent: spent, received: received)
            defer { try? FileManager.default.removeItem(at: folder) }
            let candidates = try await db.swapHistoryCandidates(walletID: "w")
            try await db.saveSwapHistoryEvidence(e, candidate: XCTUnwrap(candidates.first))
            let rows = try await db.chainHistory(walletID: "w", currency: "USD")
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.entry.direction, "swap")
            XCTAssertEqual(rows.first?.entry.amountAtomic, spent)
            XCTAssertEqual(rows.first?.receivedAtomic, received)
            XCTAssertEqual(rows.first?.outputHolding?.reference, output)
            let details = try await db.transactionDetails(accountID: "a", transactionID: "tx")
            XCTAssertEqual(details?.swap?.id, rows.first?.id)
            // A later provider may serve the receipt but not historical traces.
            try await db.saveSwapHistoryEvidence(.init(transaction: e.transaction, receipt: e.receipt), candidate: XCTUnwrap(candidates.first))
            let afterOutage = try await db.chainHistory(walletID: "w", currency: "USD")
            XCTAssertEqual(afterOutage.map(\.id), rows.map(\.id))
            XCTAssertEqual(afterOutage.first?.receivedAtomic, received)
            try db.pool.close()
            let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
            let restored = try await reopened.chainHistory(walletID: "w", currency: "USD")
            XCTAssertEqual(restored.map(\.id), rows.map(\.id))
            XCTAssertEqual(restored.first?.receivedAtomic, received)
            try reopened.pool.close()
        }
    }
    func testCCTPBurnAppearsAsBridgeWithoutInventingDestinationPayment() async throws {
        let e = try evidence("HistoryBridges", "sepolia-cctp-source")
        let (db, folder) = try await seed(e, input: "0x1c7d4b196cb0c7b01d743fbc6116a902379c7238", output: nil, spent: "100000000", received: nil)
        defer { try? FileManager.default.removeItem(at: folder) }
        let candidates = try await db.swapHistoryCandidates(walletID: "w")
        try await db.saveSwapHistoryEvidence(e, candidate: XCTUnwrap(candidates.first))
        let rows = try await db.chainHistory(walletID: "w", currency: "USD")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.entry.direction, "bridgeOutgoing")
        XCTAssertEqual(rows.first?.entry.amountAtomic, "100000000")
        XCTAssertNil(rows.first?.receivedAtomic)
        try db.pool.close()
    }
    private func seed(_ e: EVMHistoryEvidence, input: String, output: String?, spent: String, received: String?) async throws -> (OathDatabase, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        var assets = [AssetRecord(id: "input", networkID: "ethereumSepolia", reference: input, name: "Input", symbol: "IN", decimals: input == "native" ? 18 : 6)]
        if let output { assets.append(.init(id: "output", networkID: "ethereumSepolia", reference: output, name: "Output", symbol: "OUT", decimals: output == "native" ? 18 : 6)) }
        try await db.seed(networks: [.init(id: "ethereumSepolia", name: "Sepolia", family: "evm", symbol: "ETH", decimals: 18, derivationPath: "", logo: "", sortOrder: 0)], assets: assets)
        try await db.importWalletIfNeeded(.init(id: "w", name: "Test", kind: "hd", vaultReference: "test", createdAt: 1),
            accounts: [.init(id: "a", walletID: "w", networkID: "ethereumSepolia", address: e.transaction["from"].string!, derivationPath: "")])
        var batch = SyncBatch(cursor: .init(accountID: "a", stream: "fixture", cursor: "1", updatedAt: 100), expectedCursor: nil)
        batch.transactions = [.init(id: "tx", networkID: "ethereumSepolia", hash: e.transaction["hash"].string!, state: "confirmed",
            blockHeight: Int64(try AnkrQuantity.decimal(e.receipt["blockNumber"].string!)), blockHash: e.receipt["blockHash"].string, timestamp: 100, updatedAt: 100)]
        batch.activity = [.init(id: "sent", walletID: "w", accountID: "a", networkID: "ethereumSepolia", transactionID: "tx", assetID: "input", direction: "outgoing", amountAtomic: spent, counterparty: "", timestamp: 100)]
        if let received { batch.activity.append(.init(id: "received", walletID: "w", accountID: "a", networkID: "ethereumSepolia", transactionID: "tx", assetID: "output", direction: "incoming", amountAtomic: received, counterparty: "", timestamp: 100)) }
        try await db.apply(batch)
        return (db, folder)
    }
}

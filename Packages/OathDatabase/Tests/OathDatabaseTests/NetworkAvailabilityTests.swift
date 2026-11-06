import XCTest
@testable import OathDatabase

@MainActor final class NetworkAvailabilityTests: XCTestCase {
    func testDisableHidesExistingHoldingsAndPreservesDataForReenable() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        try await db.seed(networks: ["cronos", "ethereum"].enumerated().map {
            .init(id: $0.element, name: $0.element, family: "evm", symbol: $0.element == "cronos" ? "CRO" : "ETH", decimals: 18, derivationPath: "fixture", logo: "fixture", sortOrder: $0.offset)
        }, assets: ["cronos", "ethereum"].map {
            .init(id: $0 + ":native", networkID: $0, reference: "native", name: $0, symbol: $0, decimals: 18)
        })
        try await db.importWalletIfNeeded(.init(id: "wallet", name: "Fixture", kind: "hd", vaultReference: "fixture", createdAt: 1), accounts: ["cronos", "ethereum"].map {
            .init(id: $0, walletID: "wallet", networkID: $0, address: "0x" + String(repeating: "1", count: 40), derivationPath: "fixture")
        })
        try await db.saveBalances([.init(accountID: "cronos", assetID: "cronos:native", networkID: "cronos", amountAtomic: "123", observedAt: 1, blockHeight: 1, source: "fixture")])
        try await db.setNetworkEnabled("cronos", enabled: false)
        try await db.setNetworkEnabled("cronos", enabled: false)
        let disabled = try await db.snapshot(walletID: "wallet", currency: "USD")
        XCTAssertFalse(disabled.holdings.contains { $0.networkID == "cronos" })
        XCTAssertFalse(disabled.networks.contains { $0.id == "cronos" })
        XCTAssertTrue(disabled.networks.contains { $0.id == "ethereum" })
        XCTAssertTrue(disabled.accounts.contains { $0.networkID == "cronos" })
        let retained = try await db.balance(accountID: "cronos", assetID: "cronos:native")
        XCTAssertEqual(retained?.amountAtomic, "123")
        try await db.setNetworkEnabled("cronos", enabled: true)
        let restored = try await db.snapshot(walletID: "wallet", currency: "USD")
        XCTAssertEqual(restored.holdings.first { $0.networkID == "cronos" }?.amountAtomic, "123")
        XCTAssertTrue(restored.networks.contains { $0.id == "cronos" })
    }
}

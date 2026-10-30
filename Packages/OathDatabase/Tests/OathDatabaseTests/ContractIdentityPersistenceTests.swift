import XCTest
import OathAnkr
@testable import OathDatabase

@MainActor final class ContractIdentityPersistenceTests: XCTestCase {
    private let address = "0x" + String(repeating: "a", count: 40)

    func testCatalogNamesDoNotRequireAnyWalletHolding() async throws {
        let (db, folder, _) = try await EVMSendJournalTests().fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await db.saveAsset(.init(id: "arbitrum:" + address, networkID: "arbitrum", reference: address,
            name: "Sold token", symbol: "SOLD", decimals: 6))
        let values = try await db.contractIdentities(network: "arbitrum", addresses: [address, address.uppercased().replacingOccurrences(of: "0X", with: "0x")])
        XCTAssertEqual(values.count, 1); XCTAssertEqual(values.first?.name, "Sold token")
        XCTAssertEqual(values.first?.decimals, 6); XCTAssertEqual(values.first?.source, .catalog)
    }

    func testNamesSurviveRestartWithoutCreatingHoldingsAndAreChainScoped() async throws {
        let (db, folder, _) = try await EVMSendJournalTests().fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let value = try ContractIdentity(network: "arbitrum", address: address, name: "Contract", source: .sourcify)
        try await db.saveContractIdentities([value])
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        let cached = try await reopened.contractIdentities(network: "arbitrum", addresses: [address])
        XCTAssertEqual(cached, [value])
        let other = try await reopened.contractIdentities(network: "ethereum", addresses: [address])
        XCTAssertTrue(other.isEmpty)
        let asset = try await reopened.asset(networkID: "arbitrum", reference: address)
        XCTAssertNil(asset, "A spender name must not insert a portfolio token")
    }

    func testStaleNamesRemainAvailableAndOlderWritesCannotReplaceNewer() async throws {
        let (db, folder, _) = try await EVMSendJournalTests().fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = try ContractIdentity(network: "arbitrum", address: address, name: "Old", source: .onChain, checkedAt: .init(timeIntervalSince1970: 1))
        let current = try ContractIdentity(network: "arbitrum", address: address, name: "Current", source: .onChain, checkedAt: .init(timeIntervalSince1970: 2))
        try await db.saveContractIdentities([old, current, old])
        let values = try await db.contractIdentities(network: "arbitrum", addresses: [address])
        XCTAssertEqual(values, [current], "Offline or failed refresh must retain a stale successful identity")
        try await db.saveContractIdentities([])
        let unchanged = try await db.contractIdentities(network: "arbitrum", addresses: [address])
        XCTAssertEqual(unchanged, [current])
    }

    func testCatalogTokenNameUpgradesGenericVerifiedProxyName() async throws {
        let (db, folder, _) = try await EVMSendJournalTests().fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await db.saveContractIdentities([ContractIdentity(network: "arbitrum", address: address, name: "Proxy", source: .sourcify)])
        try await db.saveAsset(.init(id: "arbitrum:" + address, networkID: "arbitrum", reference: address, name: "Token Name", symbol: "TOKEN", decimals: 6))
        let values = try await db.contractIdentities(network: "arbitrum", addresses: [address])
        XCTAssertEqual(values.first?.name, "Token Name"); XCTAssertEqual(values.first?.decimals, 6)
    }

    func testMissingNamesStayMissingAndInvalidIdentitiesAreRejected() async throws {
        let (db, folder, _) = try await EVMSendJournalTests().fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let missing = try await db.contractIdentities(network: "arbitrum", addresses: [address])
        XCTAssertTrue(missing.isEmpty)
        do { _ = try await db.contractIdentities(network: "arbitrum", addresses: ["bad"]); XCTFail("Invalid address accepted") } catch {}
        let invalid = try JSONDecoder().decode(ContractIdentity.self, from: Data("""
            {"network":"arbitrum","address":"\(address)","name":"bad\\u202ename","decimals":18,"source":"onChain","checkedAt":1}
            """.utf8))
        do { try await db.saveContractIdentities([invalid]); XCTFail("Invalid decoded metadata persisted") } catch {}
    }

    func testPublicCacheRemainsBounded() async throws {
        let (db, folder, _) = try await EVMSendJournalTests().fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        for start in stride(from: 1, through: 4001, by: 1000) {
            let values = try (start..<min(start+1000, 4002)).map { i in
                try ContractIdentity(network: "arbitrum", address: "0x" + String(format: "%040x", i), name: "Token \(i)", source: .onChain, checkedAt: .init(timeIntervalSince1970: Double(i)))
            }
            try await db.saveContractIdentities(values)
        }
        let oldest = try await db.contractIdentities(network: "arbitrum", addresses: ["0x" + String(format: "%040x", 1)])
        let newest = try await db.contractIdentities(network: "arbitrum", addresses: ["0x" + String(format: "%040x", 4001)])
        XCTAssertTrue(oldest.isEmpty); XCTAssertEqual(newest.first?.name, "Token 4001")
    }
}

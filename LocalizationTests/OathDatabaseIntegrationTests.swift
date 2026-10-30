import Foundation
import XCTest
import OathDatabase
@testable import OathAtmosphere

func makeTestDatabase() async throws -> OathDatabase {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("OathSQLFixture-" + UUID().uuidString)
        .appendingPathComponent("wallet.sqlite")
    let database = try await OathDatabase.open(at: url)
    try await OathDataEnvironment.seed(database)
    return database
}

@MainActor final class OathDatabaseIntegrationTests: XCTestCase {
    func testAllSupportedNetworksAreSeededOnce() async throws {
        let database = try await makeTestDatabase()
        try await OathDataEnvironment.seed(database)
        let networks = try await database.networks()
        XCTAssertEqual(networks.count, 30)
        XCTAssertEqual(Set(networks.map(\.id)), Set(OathImportChain.allCases.map(\.id)))
    }

    func testStoredProfileUsesDatabaseAccountIdentity() async throws {
        let database = try await makeTestDatabase()
        let id = UUID().uuidString
        try await database.importWalletIfNeeded(
            WalletRecord(id: id, name: "Public fixture", kind: "watchOnly", vaultReference: "fixture", createdAt: 1),
            accounts: [AccountRecord(id: "account", walletID: id, networkID: "bitcoin", address: "public-fixture", derivationPath: "fixture")])
        let snapshot = try await database.snapshot(walletID: id, currency: "USD")
        let profile = try OathWalletProfile.stored(snapshot)
        XCTAssertEqual(profile.addresses.first?.accountID, "account")
        XCTAssertEqual(profile.addresses.first?.assetID, "bitcoin:native")
        XCTAssertNil(snapshot.holdings.first?.amountAtomic)
        XCTAssertEqual(snapshot.totalFiat, 0)
    }
}

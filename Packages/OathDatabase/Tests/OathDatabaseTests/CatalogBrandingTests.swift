import XCTest
import GRDB
@testable import OathDatabase

final class CatalogBrandingTests: XCTestCase {
    private let oldNetwork = NetworkRecord(id: "ton", name: "TON", family: "account", symbol: "TON",
        decimals: 9, derivationPath: "m/44'/607'/0'", logo: "old-logo", sortOrder: 19, enabled: false)
    private let oldAsset = AssetRecord(id: "ton:native", networkID: "ton", reference: "native",
        name: "Toncoin", symbol: "TON", decimals: 9, logo: "old-logo")
    private var newNetwork: NetworkRecord {
        NetworkRecord(id: "ton", name: "Gram", family: "account", symbol: "GRAM", decimals: 9,
                      derivationPath: "m/44'/607'/0'", logo: "network-ton", sortOrder: 5)
    }
    private var newAsset: AssetRecord {
        AssetRecord(id: "ton:native", networkID: "ton", reference: "native",
                    name: "Gram", symbol: "GRAM", decimals: 9, logo: "network-ton")
    }

    func testExistingWalletReceivesBrandingWithoutChangingIdentityOrBalances() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("catalog.sqlite")
        let database = try await OathDatabase.open(at: url)
        try await database.seed(networks: [oldNetwork], assets: [oldAsset])
        let wallet = WalletRecord(id: "wallet", name: "My saved wallet", kind: "watchOnly",
                                  vaultReference: "public-fixture", createdAt: 1)
        let account = AccountRecord(id: "account", walletID: "wallet", networkID: "ton",
                                    address: "public-fixture", derivationPath: oldNetwork.derivationPath)
        try await database.importWalletIfNeeded(wallet, accounts: [account])
        let importedWallet = try await database.wallet(wallet.id)
        let balance = BalanceRecord(accountID: account.id, assetID: oldAsset.id, networkID: "ton",
                                    amountAtomic: "12345678901", observedAt: 1, source: "fixture")
        try await database.saveBalances([balance])
        try await database.setSetting("appearance", value: "light")
        try await database.seed(networks: [newNetwork], assets: [newAsset])
        // A second startup is idempotent and persists the same metadata.
        try await database.seed(networks: [newNetwork], assets: [newAsset])
        let reopened = try await OathDatabase.open(at: url)
        let networks = try await reopened.networks(enabledOnly: false)
        var expected = oldNetwork
        expected.name = "Gram"; expected.symbol = "GRAM"; expected.logo = "network-ton"
        XCTAssertEqual(networks, [expected])
        let snapshot = try await reopened.snapshot(walletID: wallet.id, currency: "USD")
        XCTAssertEqual(snapshot.wallet, importedWallet)
        XCTAssertEqual(snapshot.accounts, [account])
        XCTAssertEqual(snapshot.settings["appearance"], "light")
        let savedBalance = try await reopened.balance(accountID: account.id, assetID: oldAsset.id)
        XCTAssertEqual(savedBalance, balance)
        let asset = try await reopened.pool.read { try AssetRecord.fetchOne($0, key: "ton:native") }
        XCTAssertEqual(asset, newAsset)
    }

    func testConflictingAssetIdentityRollsBackBrandingUpdate() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try await OathDatabase.open(at: folder.appendingPathComponent("catalog.sqlite"))
        try await database.seed(networks: [oldNetwork], assets: [oldAsset])
        var conflicting = newAsset
        conflicting.reference = "another-token"
        do {
            try await database.seed(networks: [newNetwork], assets: [conflicting])
            XCTFail("A branding update must not repurpose an asset identity")
        } catch {
            XCTAssertEqual(error as? StoreError, .conflictingIdentity)
        }
        let networks = try await database.networks(enabledOnly: false)
        XCTAssertEqual(networks, [oldNetwork])
        let asset = try await database.pool.read { try AssetRecord.fetchOne($0, key: "ton:native") }
        XCTAssertEqual(asset, oldAsset)
    }
}

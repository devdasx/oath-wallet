import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class ArtworkPersistenceTests: XCTestCase {
    func testAnkrRefreshHealsMissingAndStaleLogosWithoutChangingIdentity() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        // Exercise every supported Ankr EVM network, not just Ethereum.
        try await database.pool.write { db in
            for chain in AnkrChain.allCases {
                let network = chain.networkID
                try NetworkRecord(id: network, name: network, family: "evm", symbol: "ETH", decimals: 18,
                    derivationPath: "fixture", logo: "network-" + network, sortOrder: 0).insert(db)
                let reference = "0x" + String(repeating: "1", count: 40)
                let initial = try OathDatabase.ankrAsset(networkID: network, reference: reference, name: "User name", symbol: "TOKEN", decimals: 6, logo: nil, db: db)
                XCTAssertNil(initial.logo)
                let healed = try OathDatabase.ankrAsset(networkID: network, reference: reference, name: "Provider name", symbol: "OTHER", decimals: 6,
                    logo: "https://cdn.example.org/new.svg", db: db)
                XCTAssertEqual(healed.logo, "https://cdn.example.org/new.svg")
                XCTAssertEqual(healed.name, "User name"); XCTAssertEqual(healed.symbol, "TOKEN"); XCTAssertEqual(healed.id, initial.id)
                let retained = try OathDatabase.ankrAsset(networkID: network, reference: reference, name: "Other", symbol: "OTHER", decimals: 6, logo: nil, db: db)
                XCTAssertEqual(retained.logo, healed.logo)
                let updated = try OathDatabase.ankrAsset(networkID: network, reference: reference, name: "Other", symbol: "OTHER", decimals: 6,
                    logo: "https://cdn.example.org/revised.png", db: db)
                XCTAssertEqual(updated.logo, "https://cdn.example.org/revised.png")
                XCTAssertThrowsError(try OathDatabase.ankrAsset(networkID: network, reference: reference, name: "Wrong", symbol: "WRONG", decimals: 18, logo: nil, db: db))
                try AssetRecord(id: network + ":native", networkID: network, reference: "native", name: "Native", symbol: "ETH", decimals: 18, logo: "network-" + network).insert(db)
                let native = try OathDatabase.ankrAsset(networkID: network, reference: "native", name: "Provider native", symbol: "ETH", decimals: 18,
                    logo: "https://cdn.example.org/native.png", db: db)
                XCTAssertEqual(native.logo, "network-" + network)
            }
        }
    }
    func testSolanaAndTronKeepSavedArtworkWhenCatalogOmitsIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        try await database.pool.write { db in
            for network in ["solana", "tron"] {
                try NetworkRecord(id: network, name: network, family: "account", symbol: "TOKEN", decimals: 6,
                    derivationPath: "fixture", logo: "network-" + network, sortOrder: 0).insert(db)
            }
            let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", logo = "https://cdn.example.org/token.svg"
            let first = try OathDatabase.solanaAsset(mint: mint, decimals: 6,
                info: .init(address: mint, name: "USDC", symbol: "USDC", decimals: 6, logo: logo), db: db)
            let next = try OathDatabase.solanaAsset(mint: mint, decimals: 6,
                info: .init(address: mint, name: "USDC", symbol: "USDC", decimals: 6, logo: nil), db: db)
            XCTAssertEqual(next.logo, first.logo)
            let tron = TronIdentity.usdt
            let token = TronToken(reference: tron, name: "USDT", symbol: "USDT", decimals: 6, logo: logo)
            let t1 = try OathDatabase.tronAsset(token, catalog: [:], db: db)
            let t2 = try OathDatabase.tronAsset(token, catalog: [tron: .init(address: tron, name: "USDT", symbol: "USDT", decimals: 6, logo: nil)], db: db)
            XCTAssertEqual(t2.logo, t1.logo)
        }
    }
}

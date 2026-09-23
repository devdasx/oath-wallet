import Foundation
import GRDB
import Testing
import UIKit
@testable import Aperture

struct PushNotificationLogoTests {
    private func notification(network: String, symbol: String) -> DBNotificationRecord {
        DBNotificationRecord(
            id: "logo-test", profileID: WalletDatabase.defaultProfileID, category: "received",
            titleKey: "notification.received.title", bodyKey: "notification.received.body.unpriced",
            argumentsJSON: nil, relatedTransactionID: nil, createdAt: 0, readAt: nil, deliveredAt: nil,
            networkID: network, assetSymbol: symbol
        )
    }

    @Test @MainActor
    func bitcoinLogoLoadsFromBundleWithoutAnAssetDownload() async throws {
        let database = try WalletDatabase.temporary()
        let record = notification(network: "bitcoin", symbol: "BTC")
        let source = try await database.pool.read { db in
            try PushNotificationLogoResolver.source(for: record, in: db)
        }
        #expect(source == .nativeCoin(blockchain: .bitcoin))
        let image = await PushNotificationLogoResolver.image(for: record, database: database)
        #expect(image != nil)
    }

    @Test @MainActor
    func tokenArtworkUsesThePersistentCacheAndMissingArtworkStaysAbsent() async throws {
        let database = try WalletDatabase.temporary()
        let url = try #require(URL(string: "https://example.invalid/contract-identity.png"))
        let source = AssetLogoSource.ankrToken(
            blockchain: .ethereum, contractAddress: "0x1111111111111111111111111111111111111111",
            logoURL: url.absoluteString
        )
        let absent = await PushNotificationLogoResolver.cachedImage(for: source, database: database)
        #expect(absent == nil)
        let data = try #require(UIImage(named: "NetworkLogoEthereum")?.pngData())
        try await database.storeAssetLogoCacheEntry(
            for: url, payload: data, lifetime: 60, etag: nil, lastModified: nil
        )
        let cached = await PushNotificationLogoResolver.cachedImage(for: source, database: database)
        #expect(cached != nil)
    }

    @Test(arguments: [("solana", "BTC"), ("eth", "ETH"), ("bitcoin", "FAKE"), ("unknown", "BTC")])
    func missingIdentityNeverGuessesArtworkFromATicker(network: String, symbol: String) async throws {
        let database = try WalletDatabase.temporary()
        let record = notification(network: network, symbol: symbol)
        let source = try await database.pool.read { db in
            try PushNotificationLogoResolver.source(for: record, in: db)
        }
        #expect(source == .unavailable)
    }
}

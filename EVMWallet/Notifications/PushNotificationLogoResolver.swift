import GRDB
import UIKit

/// Notifications reuse bundled artwork and the wallet's persistent image cache.
/// Missing or unidentifiable artwork never starts a network request.
enum PushNotificationLogoResolver {
    static func source(for notification: DBNotificationRecord, in database: Database) throws -> AssetLogoSource {
        guard notification.category == "received" || notification.category == "sent" else { return .unavailable }
        if let context = try NotificationTransactionStore.context(for: notification, in: database) {
            return context.transaction.assetLogoSource
        }
        // These supported UTXO notification networks contain native coins only.
        // Do not infer a token's identity from its ticker on token-capable chains.
        if let networkID = notification.networkID,
           ["bitcoin", "bitcoin_cash", "litecoin", "dogecoin"].contains(networkID),
           let network = try DBNetworkRecord.fetchOne(database, key: networkID),
           let blockchain = WalletBlockchain(rawValue: network.trustWalletBlockchain),
           notification.assetSymbol == network.nativeSymbol {
            return .nativeCoin(blockchain: blockchain)
        }
        return .unavailable
    }

    @MainActor
    static func image(for notification: DBNotificationRecord, database: WalletDatabase) async -> UIImage? {
        guard let source = try? await database.pool.read({ db in
            try Self.source(for: notification, in: db)
        }) else { return nil }
        return await cachedImage(for: source, database: database)
    }

    @MainActor
    static func cachedImage(for source: AssetLogoSource, database: WalletDatabase) async -> UIImage? {
        if let assetName = source.bundledAssetName { return UIImage(named: assetName) }
        for url in source.logoURLs {
            guard !Task.isCancelled else { return nil }
            if let entry = try? await database.assetLogoCacheEntry(for: url),
               let image = UIImage(data: entry.payload) { return image }
        }
        return nil
    }
}

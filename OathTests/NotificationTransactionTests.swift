import Foundation
import SwiftUI
import GRDB
import Testing
import UIKit
@testable import Aperture

@Suite(.serialized)
struct NotificationTransactionTests {
    private static let hash = String(repeating: "a", count: 64)
    private static let sender = "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"
    private static let recipient = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"

    private func fixture(status: String = "pending") async throws -> (WalletDatabase, DBNotificationRecord) {
        let database = try WalletDatabase.temporary()
        try await database.pool.write { db in
            try DBWalletRecord(id: "wallet", profileID: WalletDatabase.defaultProfileID, name: "Wallet",
                kind: DatabaseWalletKind.importedRecoveryPhrase.rawValue, secretKeyReference: nil,
                isSelected: false, sortOrder: 0, createdAt: 1, updatedAt: 1, lastOpenedAt: nil, archivedAt: nil).insert(db)
            try DBWalletAccountRecord(id: "account", walletID: "wallet", networkID: "bitcoin",
                address: Self.recipient, normalizedAddress: Self.recipient, label: nil, derivationPath: nil,
                accountIndex: nil, publicKey: nil, isWatchOnly: true, isEnabled: true,
                createdAt: 1, updatedAt: 1, lastSyncedAt: nil).insert(db)
            try DBTransactionRecord(id: "transaction", accountID: "account", networkID: "bitcoin",
                transactionHash: Self.hash, normalizedTransactionHash: Self.hash, kind: "received",
                status: status, direction: "incoming", fromAddress: Self.sender, toAddress: Self.recipient,
                counterpartyAddress: Self.sender, blockNumber: nil, blockHash: nil, transactionIndex: nil,
                nonce: nil, transactionType: nil, timestamp: 1, assetID: nil, assetSymbol: "BTC",
                secondaryAssetSymbol: nil, assetAmount: "0.005573600000000001", fiatUSDValue: "429.88",
                networkFee: "0.00000123", networkFeeFiatUSDValue: nil, networkFeeSymbol: "BTC",
                gasPriceGwei: nil, gasLimit: nil, gasUsed: nil, inputData: nil, methodName: nil,
                displayDetail: "", displayTime: "", firstSeenAt: 1, updatedAt: 1).insert(db)
            try DBTransactionNoteRecord(transactionID: "transaction", note: "Invoice", createdAt: 1, updatedAt: 1).insert(db)
        }
        return (database, DBNotificationRecord(id: "notification", profileID: WalletDatabase.defaultProfileID,
            category: "received", titleKey: "notification.received.title", bodyKey: "notification.received.body.unpriced",
            argumentsJSON: nil, relatedTransactionID: nil, createdAt: 1, readAt: nil, deliveredAt: nil,
            walletID: "wallet", networkID: "bitcoin", transactionHash: Self.hash, assetSymbol: "BTC"))
    }

    @Test func resolvesInactiveWalletAndPreservesTransactionDetails() async throws {
        let (database, notification) = try await fixture()
        let context = try await database.pool.read { try NotificationTransactionStore.context(for: notification, in: $0) }
        let value = try #require(context)
        #expect(value.record.assetAmount == "0.005573600000000001")
        #expect(value.transaction.metadata.fromAddress == Self.sender)
        #expect(value.transaction.metadata.toAddress == Self.recipient)
        #expect(value.transaction.metadata.note == "Invoice")
        #expect(value.record.networkFee == "0.00000123")
        #expect(value.receipt.fromAddress == Self.recipient)
        #expect(value.notification.relatedTransactionID == "transaction")
        #expect(value.transaction.assetLogoSource == .nativeCoin(blockchain: .bitcoin))
    }

    @Test(arguments: ["wallet", "network", "symbol", "hash", "archived", "category"])
    func mismatchedNotificationCannotBorrowAnotherTransaction(field: String) async throws {
        let (database, record) = try await fixture()
        var notification = record
        switch field {
        case "wallet": notification.walletID = "another-wallet"
        case "network": notification.networkID = "eth"
        case "symbol": notification.assetSymbol = "USDT"
        case "hash": notification.transactionHash = String(repeating: "b", count: 64)
        default: break
        }
        if field == "archived" {
            try await database.pool.write { try $0.execute(sql: "UPDATE wallets SET archivedAt = 2 WHERE id = 'wallet'") }
        }
        if field == "category" {
            try await database.pool.write { try $0.execute(sql: "UPDATE transactions SET kind = 'sent' WHERE id = 'transaction'") }
        }
        let candidate = notification
        let result = try await database.pool.read { try NotificationTransactionStore.context(for: candidate, in: $0) }
        #expect(result == nil)
    }

    @Test(arguments: ["canceled", "confirmed", "failed"])
    func pendingProviderResponseCannotEraseTerminalState(status: String) async throws {
        let (database, notification) = try await fixture(status: status)
        let candidate = try await database.pool.read { try NotificationTransactionStore.context(for: notification, in: $0) }
        let context = try #require(candidate)
        try await NotificationTransactionStore.persist(.pending, context: context, database: database)
        if status == "canceled" {
            try await NotificationTransactionStore.persist(.confirmed, context: context, database: database)
        }
        let stored = try await database.pool.read { try DBTransactionRecord.fetchOne($0, key: "transaction") }
        #expect(stored?.status == status)
    }

    @Test @MainActor func monitoringPersistsRealConfirmationAndStops() async throws {
        let (database, notification) = try await fixture()
        let model = NotificationTransactionDetailModel(notification: notification, database: database,
            statusReader: { _ in .confirmed }, refreshHistory: { Issue.record("Unexpected history refresh") })
        await model.monitor()
        #expect(model.context?.transaction.status == .confirmed)
        #expect(model.failureCode == nil)
        #expect(!model.isLoading)
    }

    @Test @MainActor func canceledTransactionNeverQueriesAProvider() async throws {
        let (database, notification) = try await fixture(status: "canceled")
        let model = NotificationTransactionDetailModel(notification: notification, database: database,
            statusReader: { _ in Issue.record("Canceled transaction was queried"); return .confirmed })
        await model.monitor()
        #expect(model.context?.transaction.status == .canceled)
    }

    @Test @MainActor func providerFailureDoesNotBecomeATransactionFailure() async throws {
        let (database, notification) = try await fixture(status: "confirmed")
        let model = NotificationTransactionDetailModel(notification: notification, database: database,
            statusReader: { _ in throw URLError(.timedOut) })
        await model.monitor()
        #expect(model.context?.transaction.status == .confirmed)
        #expect(model.failureCode != nil)
    }

    @Test func base58HashesRemainCaseSensitive() {
        #expect(!NotificationTransactionStore.hashesMatch("AbC", "abc", networkID: "solana"))
        #expect(!NotificationTransactionStore.hashesMatch("AbC", "abc", networkID: "sui"))
        #expect(NotificationTransactionStore.hashesMatch("ABCD", "abcd", networkID: "bitcoin"))
    }

    @Test(arguments: NativeListTestLayout.allCases) @MainActor
    func detailsUseNativeResponsiveSections(layout: NativeListTestLayout) async throws {
        let (database, notification) = try await fixture(status: "confirmed")
        let candidate = try await database.pool.read { try NotificationTransactionStore.context(for: notification, in: $0) }
        let context = try #require(candidate)
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                NotificationTransactionDetailsContent(notification: context.notification, database: database,
                    failureCode: nil, retry: {}, transaction: context.transaction, isBalanceHidden: false)
            }
        }
        defer { host.close() }
        let list = try await host.list { $0.numberOfSections == 5 }
        #expect(list.numberOfItems(inSection: 1) == 5)
        #expect(list.numberOfItems(inSection: 2) == 2)
        let overview = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
        #expect(overview.bounds.width > 0)
        #expect(overview.bounds.height > 0)
        #expect(list.effectiveUserInterfaceLayoutDirection == (layout.direction == .rightToLeft ? .rightToLeft : .leftToRight))
    }

    @Test func tokenIdentityUsesContractAndRejectsAmbiguousTickers() async throws {
        let (database, original) = try await fixture()
        let contract = "0xdAC17F958D2ee523a2206206994597C13D831ec7"
        try await database.pool.write { db in
            try DBAssetRecord(id: "eth:token", networkID: "eth", assetType: DatabaseAssetType.fungibleToken.rawValue,
                contractAddress: contract, normalizedContractAddress: contract.lowercased(), name: "Tether", symbol: "USDT",
                decimals: 6, trustWalletBlockchain: "ethereum", trustWalletContractAddress: contract,
                isVerified: true, isSpam: false, createdAt: 1, updatedAt: 1, metadataUpdatedAt: nil).insert(db)
            try db.execute(sql: "UPDATE walletAccounts SET networkID = 'eth' WHERE id = 'account'")
            try db.execute(sql: "UPDATE transactions SET networkID = 'eth', assetID = 'eth:token', assetSymbol = 'USDT' WHERE id = 'transaction'")
        }
        var changed = original
        changed.networkID = "eth"
        changed.assetSymbol = "USDT"
        let notification = changed
        let context = try await database.pool.read { try NotificationTransactionStore.context(for: notification, in: $0) }
        #expect(context?.transaction.metadata.contractAddress == contract)
        #expect(context?.transaction.metadata.tokenDecimals == 6)
        try await database.pool.write { db in
            let record = try #require(try DBTransactionRecord.fetchOne(db, key: "transaction"))
            var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
            fields["id"] = "ambiguous"
            fields.removeValue(forKey: "assetID")
            try JSONDecoder().decode(DBTransactionRecord.self, from: JSONSerialization.data(withJSONObject: fields)).insert(db)
        }
        let ambiguous = try await database.pool.read { try NotificationTransactionStore.context(for: notification, in: $0) }
        #expect(ambiguous == nil)
        try await database.pool.write { _ = try DBTransactionRecord.deleteOne($0, key: "ambiguous") }
        // Unpriced tokens cannot bypass the app-wide transaction visibility policy.
        try await database.pool.write { try $0.execute(sql: "UPDATE transactions SET fiatUSDValue = NULL WHERE id = 'transaction'") }
        let hidden = try await database.pool.read { try NotificationTransactionStore.context(for: notification, in: $0) }
        #expect(hidden == nil)
    }

    @Test func legacyLinkedNotificationRecoversItsWalletAndNetwork() async throws {
        let (database, original) = try await fixture()
        var old = original
        old.relatedTransactionID = "transaction"
        old.walletID = nil
        old.networkID = nil
        old.transactionHash = nil
        let notification = old
        let value = try await database.pool.read { try NotificationTransactionStore.context(for: notification, in: $0) }
        #expect(value?.notification.walletID == "wallet")
        #expect(value?.notification.networkID == "bitcoin")
        #expect(value?.notification.transactionHash == Self.hash)
    }

    @Test @MainActor func missingHistoryIsRefreshedBeforeStatusIsRead() async throws {
        let (database, notification) = try await fixture()
        let saved = try await database.pool.write { db in
            let record = try #require(try DBTransactionRecord.fetchOne(db, key: "transaction"))
            try DBTransactionRecord.deleteOne(db, key: "transaction")
            return record
        }
        let model = NotificationTransactionDetailModel(notification: notification, database: database,
            statusReader: { _ in .confirmed }, refreshHistory: {
                try await database.pool.write { try saved.insert($0) }
            })
        await model.monitor()
        #expect(model.context?.transaction.status == .confirmed)
        #expect(model.failureCode == nil)
    }

    @Test @MainActor func closingPendingMonitorCancelsItsWaitWithoutChangingStatus() async throws {
        let (database, notification) = try await fixture()
        let (calls, continuation) = AsyncStream<Void>.makeStream()
        let model = NotificationTransactionDetailModel(notification: notification, database: database,
            statusReader: { _ in continuation.yield(()); return .pending })
        let task = Task { await model.monitor() }
        for await _ in calls { break }
        task.cancel()
        await task.value
        continuation.finish()
        let record = try await database.pool.read { try DBTransactionRecord.fetchOne($0, key: "transaction") }
        #expect(record?.status == "pending")
        #expect(model.failureCode == nil)
    }

    @Test(arguments: [("solana", "SOL"), ("sui", "SUI"), ("near", "NEAR")])
    func storedBase58IdentitiesResolveWithoutCaseFolding(network: String, symbol: String) async throws {
        let (database, original) = try await fixture()
        let hash = "Auxh58uWkyeA99yWP6WdJ5tK1UTcJc4nw3GT3Jcw1B2k"
        var changed = original
        changed.networkID = network
        changed.assetSymbol = symbol
        changed.transactionHash = hash
        let notification = changed
        for normalized in [hash, hash.lowercased()] {
            try await database.pool.write { db in
                try db.execute(sql: "UPDATE walletAccounts SET networkID = ? WHERE id = 'account'", arguments: [network])
                try db.execute(sql: "UPDATE transactions SET networkID = ?, assetSymbol = ?, transactionHash = ?, normalizedTransactionHash = ? WHERE id = 'transaction'",
                    arguments: [network, symbol, hash, normalized])
            }
            let value = try await database.pool.read { try NotificationTransactionStore.context(for: notification, in: $0) }
            #expect(value?.record.transactionHash == hash)
        }
        var wrongCase = notification
        wrongCase.transactionHash = hash.lowercased()
        let unrelated = wrongCase
        let rejected = try await database.pool.read { try NotificationTransactionStore.context(for: unrelated, in: $0) }
        #expect(rejected == nil)
    }

    @Test(arguments: ReceiveNetworkCatalog.catalogNetworkIdentifiers.compactMap { ReceiveNetworkCatalog.catalogNetwork(for: $0) }) @MainActor
    func everyNetworkRecoversAfterThrottlingAndIndexingDelay(network: ReceiveNetwork) async throws {
        let (database, original) = try await fixture()
        var updated = original
        updated.networkID = network.id
        updated.assetSymbol = network.symbol
        let notification = updated
        let saved = try await database.pool.write { db in
            try db.execute(sql: "UPDATE walletAccounts SET networkID = ? WHERE id = 'account'", arguments: [network.id])
            try db.execute(sql: "UPDATE transactions SET networkID = ?, assetSymbol = ? WHERE id = 'transaction'",
                           arguments: [network.id, network.symbol])
            let saved = try #require(try DBTransactionRecord.fetchOne(db, key: "transaction"))
            try DBTransactionRecord.deleteOne(db, key: "transaction")
            return saved
        }
        let probe = NotificationRetryProbe()
        let model = NotificationTransactionDetailModel(
            notification: notification, database: database,
            statusReader: { context in
                #expect(context.record.networkID == network.id)
                #expect(context.account.walletID == "wallet")
                return .confirmed
            },
            refreshHistory: {
                let attempt = await probe.next()
                if attempt == 1 { throw NotificationTransactionRefreshFailure(code: "http_status_429") }
                if attempt == 2 { return } // Push arrived before the history index.
                try await database.pool.write { try saved.insert($0) }
            },
            sleep: { await probe.wait($0) }
        )
        await model.monitor()
        #expect(await probe.calls == 3)
        #expect(await probe.delays == [.seconds(30), .seconds(16)])
        #expect(model.context?.record.networkID == network.id)
        #expect(model.context?.transaction.status == .confirmed)
        #expect(model.failureCode == nil)
        #expect(!model.isLoading)
        // Both the history and status routers must support each advertised chain.
        _ = try SendTransactionStatusRoute.resolve(networkID: network.id)
        _ = try SendPostBroadcastChainRefreshRoute.resolve(networkID: network.id)
    }

    @Test @MainActor func partialRefreshStillDisplaysPersistedDetails() async throws {
        let (database, notification) = try await fixture()
        let saved = try await database.pool.write { db in
            let saved = try #require(try DBTransactionRecord.fetchOne(db, key: "transaction"))
            try DBTransactionRecord.deleteOne(db, key: "transaction")
            return saved
        }
        let model = NotificationTransactionDetailModel(notification: notification, database: database,
            statusReader: { _ in .confirmed }, refreshHistory: {
                try await database.pool.write { try saved.insert($0) }
                throw NotificationTransactionRefreshFailure(code: "price_http_status_429")
            }, sleep: { _ in Issue.record("Persisted details must not wait for another refresh") })
        await model.monitor()
        #expect(model.context?.transaction.status == .confirmed)
    }

    @Test @MainActor func closingUnresolvedDetailsStopsHistoryRetries() async throws {
        let (database, notification) = try await fixture()
        try await database.pool.write { try DBTransactionRecord.deleteOne($0, key: "transaction") }
        let probe = NotificationRetryProbe()
        let (waits, continuation) = AsyncStream<Void>.makeStream()
        let model = NotificationTransactionDetailModel(notification: notification, database: database,
            statusReader: { _ in Issue.record("No transaction to query"); return .pending },
            refreshHistory: { _ = await probe.next(); throw URLError(.notConnectedToInternet) },
            sleep: { _ in
                continuation.yield(())
                try await Task.sleep(for: .seconds(60))
            })
        let task = Task { await model.run() }
        for await _ in waits { break }
        #expect(model.context == nil)
        #expect(model.isLoading)
        task.cancel()
        await task.value
        continuation.finish()
        #expect(await probe.calls == 1)
        #expect(model.context == nil)
    }

    @Test(arguments: ["tron", "bitcoin", "eth", "arc"])
    func prefixedPushHashResolvesUnprefixedHistory(network: String) async throws {
        let (database, original) = try await fixture()
        let symbol = try #require(ReceiveNetworkCatalog.catalogNetwork(for: network)).symbol
        try await database.pool.write { db in
            try db.execute(sql: "UPDATE walletAccounts SET networkID = ? WHERE id = 'account'", arguments: [network])
            try db.execute(sql: "UPDATE transactions SET networkID = ?, assetSymbol = ? WHERE id = 'transaction'", arguments: [network, symbol])
        }
        var changed = original
        changed.networkID = network
        changed.assetSymbol = symbol
        changed.transactionHash = "0x" + Self.hash.uppercased()
        let notification = changed
        let context = try await database.pool.read { try NotificationTransactionStore.context(for: notification, in: $0) }
        #expect(context?.record.id == "transaction")
    }

    @Test(arguments: NativeListTestLayout.allCases) @MainActor
    func skeletonMirrorsDetailsSections(layout: NativeListTestLayout) async throws {
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack { NotificationTransactionSkeleton() }
        }
        defer { host.close() }
        let list = try await host.list { $0.numberOfSections == 5 }
        #expect(list.numberOfItems(inSection: 0) == 1)
        #expect(list.numberOfItems(inSection: 1) == 5)
        #expect(list.numberOfItems(inSection: 2) == 2)
        let hero = try await host.cell(at: IndexPath(item: 0, section: 0), in: list)
        #expect(hero.bounds.height >= 150)
        #expect(hero.bounds.width > 0)
        if layout == .phone || layout == .largeTextRTL {
            list.setContentOffset(.zero, animated: false)
            host.rootView.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: host.rootView.bounds).image { _ in
                host.rootView.drawHierarchy(in: host.rootView.bounds, afterScreenUpdates: true)
            }
            try image.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("notification-skeleton-\(layout)-review.png"))
        }
    }

    @Test @MainActor
    func notificationOpensDetailsAtSheetRootWithoutBackButton() async throws {
        let (database, notification) = try await fixture(status: "canceled")
        try await database.pool.write { try notification.insert($0) }
        let host = try NativeListTestHost {
            NavigationStack {
                PushNotificationInboxScreen(database: database, initialNotificationID: notification.id)
            }
            .environment(\.scenePhase, .active)
        }
        defer { host.close() }
        _ = try await host.list { $0.numberOfSections == 5 && $0.numberOfItems(inSection: 3) == 2 }
        let navigation = try #require(host.navigationController)
        #expect(navigation.viewControllers.count == 1)
        let item = try #require(navigation.topViewController?.navigationItem)
        #expect(item.title == WalletLocalization.string("wallet.transaction.details.title"))
        #expect(item.hidesBackButton)
        // iOS 27 places role-based Close in its native bar's button group;
        // navigationItem.leftBarButtonItems does not describe that group.
        let closeTitle = WalletAppLanguage.localizedBundle(for: "en")
            .localizedString(forKey: "common.close", value: nil, table: nil)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.views(UIButton.self, in: navigation.navigationBar)
                .contains { $0.accessibilityLabel == closeTitle }
        }
        let close = try #require(SendEntryUIProbe.views(UIButton.self, in: navigation.navigationBar)
            .first { $0.accessibilityLabel == closeTitle })
        #expect(close.isEnabled)
        #expect(close.bounds.width > 0 && close.bounds.height > 0)
        let image = UIGraphicsImageRenderer(bounds: host.rootView.bounds).image { _ in
            host.rootView.drawHierarchy(in: host.rootView.bounds, afterScreenUpdates: true)
        }
        try image.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notification-details-review.png"))
    }

    @Test @MainActor func retryDelayIsBoundedAndRateLimitsBackOff() {
        #expect(NotificationTransactionDetailModel.retryDelay(attempt: 0, code: nil) == .seconds(4))
        #expect(NotificationTransactionDetailModel.retryDelay(attempt: 100, code: nil) == .seconds(30))
        #expect(NotificationTransactionDetailModel.retryDelay(attempt: 0, code: "http_status_429") == .seconds(30))
    }

}

private actor NotificationRetryProbe {
    var calls = 0
    var delays: [Duration] = []
    func next() -> Int { calls += 1; return calls }
    func wait(_ delay: Duration) { delays.append(delay) }
}

import Foundation
import GRDB
import Testing
@testable import Aperture

@MainActor @Suite(.serialized)
struct WalletPendingActivityTests {
    @Test func pendingSurvivesBannerDismissalAndFailuresNeedReview() throws {
        let database = try WalletDatabase.temporary()
        let operation = SendOperation(database: database, draft: SendEntryTestFixtures.draft(),
                                      walletAddress: "wallet", nativeUnitUSDPrice: nil)
        let sends = SendActivityStore(operations: [operation])
        let pending = WalletPendingActivityStore()
        sends.dismissCapsule(operation)
        #expect(sends.visibleOperation(walletAddress: "wallet") == nil)
        #expect(pending.items(operations: sends.operations, walletAddress: "wallet").count == 1)
        #expect(pending.items(operations: sends.operations, walletAddress: "other").isEmpty)
        operation.phase = .failed(.insufficientAssetBalance)
        #expect(pending.items(operations: sends.operations, walletAddress: "wallet").count == 1)
        sends.finishDetails(operation)
        #expect(pending.items(operations: sends.operations, walletAddress: "wallet").isEmpty)
    }

    @Test func observedIncomingFailureIsRetainedUntilReviewed() {
        let store = WalletPendingActivityStore()
        store.prepareObservation(walletID: "wallet")
        store.apply([transaction("incoming", status: .pending), transaction("historic", status: .failed)])
        #expect(store.transactions.map(\.id) == ["incoming"])
        let failed = transaction("incoming", status: .failed)
        store.apply([failed])
        #expect(store.transactions.count == 1)
        store.prepareObservation(walletID: "wallet")
        #expect(store.transactions.count == 1)
        store.review(failed)
        store.apply([failed])
        #expect(store.transactions.isEmpty)
        store.apply([transaction("next", status: .pending)])
        store.apply([transaction("next", status: .confirmed)])
        #expect(store.transactions.isEmpty)
        store.reset(walletID: "other")
        #expect(store.transactions.isEmpty)
        #expect(!store.isPresented)
    }

    @Test func persistedQueueIncludesBothDirectionsAcrossAllAccountsAndMoreThanHomeHistoryLimit() async throws {
        let database = try WalletDatabase.temporary()
        let scope = try await SendRecipientHistoryTestFixtures.seed(database)
        let otherScope = try await SendRecipientHistoryTestFixtures.seed(database, walletID: "other", selected: false)
        let records = (0..<105).map { index in
            SendRecipientHistoryTestFixtures.transaction(id: "p-\(index)", hash: "hash-\(index)", scope: scope,
                kind: index.isMultiple(of: 2) ? "received" : "sent",
                direction: index.isMultiple(of: 2) ? "incoming" : "outgoing", status: "pending")
        }
        try await SendRecipientHistoryTestFixtures.save(records + [
            SendRecipientHistoryTestFixtures.transaction(id: "other", scope: otherScope, status: "pending"),
            SendRecipientHistoryTestFixtures.transaction(id: "old-failure", scope: scope, status: "failed")
        ], in: database)
        let result = try await database.pool.read {
            try WalletDatabase.pendingActivity(walletID: scope.walletID, since: Date(), database: $0)
        }
        #expect(result.count == 105)
        #expect(result.contains { if case .received = $0.kind { true } else { false } })
        #expect(result.contains { if case .sent = $0.kind { true } else { false } })
        #expect(!result.contains { $0.id == "other" || $0.id == "old-failure" })
    }

    @Test func oneOnChainTransactionIsNotCountedTwiceAndLiveConfirmationWins() async throws {
        let database = try WalletDatabase.temporary()
        let scope = try await SendRecipientHistoryTestFixtures.seed(database)
        let receipt = SendRecipientHistoryTestFixtures.receipt(hash: "0xABC123")
        try await SendRecipientHistoryTestFixtures.save([
            SendRecipientHistoryTestFixtures.transaction(id: "cached", hash: "0xabc123", scope: scope, status: "pending")
        ], in: database)
        let result = try await database.pool.read {
            try WalletDatabase.pendingActivity(walletID: scope.walletID, since: Date(), database: $0)
        }
        let operation = SendOperation(database: database, draft: SendEntryTestFixtures.draft(),
                                      walletAddress: "wallet", nativeUnitUSDPrice: nil)
        operation.phase = .submitted(.init(receipt: receipt, localTransactionID: "cached", localPersistenceWarningCode: nil))
        let store = WalletPendingActivityStore()
        store.apply(result)
        #expect(store.items(operations: [operation], walletAddress: "wallet").count == 1)
        operation.applyMonitoredStatus(.confirmed)
        #expect(store.items(operations: [operation], walletAddress: "wallet").isEmpty)
    }

    @Test func observationReceivesConfirmationWithoutAHomeRefresh() async throws {
        let database = try WalletDatabase.temporary()
        let scope = try await SendRecipientHistoryTestFixtures.seed(database)
        try await SendRecipientHistoryTestFixtures.save([
            SendRecipientHistoryTestFixtures.transaction(id: "watched", scope: scope, status: "pending")
        ], in: database)
        let since = Date()
        var iterator = database.pendingActivity(walletID: scope.walletID, since: since).makeAsyncIterator()
        let initial = try #require(try await iterator.next())
        #expect(initial.first?.status == .pending)
        try await database.pool.write {
            try $0.execute(sql: "UPDATE transactions SET status = 'confirmed', updatedAt = ? WHERE id = ?",
                arguments: [Date().timeIntervalSince1970, "watched"])
        }
        let updated = try #require(try await iterator.next())
        #expect(updated.isEmpty)
        var receiptIterator = database.pendingActivityTransaction(id: "watched").makeAsyncIterator()
        let receipt = try #require(try await receiptIterator.next())
        #expect(receipt?.status == .confirmed)
    }

    @Test func toolbarReservesSpaceAndHashIdentityKeepsCaseSensitiveNetworks() {
        let base = WalletHomeTopToolbarLayout.switcherTitleMaximumWidth(containerWidth: 393)
        let active = WalletHomeTopToolbarLayout.switcherTitleMaximumWidth(containerWidth: 393, showsPendingActivity: true)
        #expect(active < base)
        #expect(active >= 0)
        #expect(WalletPendingActivityItem.identity(network: "sol", hash: "AbC")
            != WalletPendingActivityItem.identity(network: "sol", hash: "abc"))
    }

    private func transaction(_ id: String, status: WalletTransactionStatus) -> WalletTransaction {
        WalletTransaction(id: id, kind: .received(assetSymbol: "ETH"), detail: "", time: "",
            assetLogoSource: .nativeCoin(blockchain: .ethereum), assetAmount: 1,
            assetSymbol: "ETH", fiatValue: nil, status: status)
    }
}

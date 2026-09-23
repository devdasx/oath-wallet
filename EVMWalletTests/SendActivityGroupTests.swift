import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor @Suite(.serialized)
struct SendActivityGroupTests {
    @Test func countAndStableOrderAreScopedToTheWallet() throws {
        let database = try WalletDatabase.temporary()
        let first = operation(database)
        let second = operation(database)
        let third = operation(database)
        let other = operation(database, wallet: "other")
        let store = SendActivityStore(operations: [first, second, third, other])
        #expect(store.visibleOperations(walletAddress: "wallet").map(\.id) == [third.id, second.id, first.id])
        fail(first)
        #expect(store.visibleOperation(walletAddress: "wallet")?.id == first.id)
        #expect(store.visibleOperations(walletAddress: "wallet").map(\.id) == [third.id, second.id, first.id])
        store.dismissCapsule(second)
        #expect(store.visibleOperations(walletAddress: "wallet").map(\.id) == [third.id, first.id])
        #expect(store.visibleOperations(walletAddress: "other").map(\.id) == [other.id])
    }

    @Test func openingOneReceiptKeepsTheExpandedGroupAndOtherTransactions() throws {
        let database = try WalletDatabase.temporary()
        let first = operation(database)
        let second = operation(database)
        fail(first)
        let store = SendActivityStore(operations: [first, second])
        store.expandActivities(walletAddress: "wallet")
        store.openDetails(first)
        #expect(store.presentedOperation?.id == first.id)
        #expect(store.expandedWalletAddress == "wallet")
        store.finishDetails(first)
        #expect(store.presentedOperation == nil)
        #expect(first.isAcknowledged)
        #expect(!second.isAcknowledged)
        #expect(store.expandedWalletAddress == "wallet")
        store.openDetails(second)
        store.finishDetails(second)
        #expect(second.isSubmitting)
        #expect(!second.isAcknowledged)
        #expect(store.expandedWalletAddress == "wallet")
        store.dismissCapsule(second)
        #expect(store.expandedWalletAddress == nil)
    }

    @Test func collapsingDoesNotAcknowledgeTransactionsAndEmptyGroupsDoNotExpand() throws {
        let database = try WalletDatabase.temporary()
        let pending = operation(database)
        let store = SendActivityStore(operations: [pending])
        store.expandActivities(walletAddress: "missing")
        #expect(store.expandedWalletAddress == nil)
        store.expandActivities(walletAddress: "wallet")
        store.collapseActivities()
        #expect(!pending.isAcknowledged)
        #expect(store.visibleOperations(walletAddress: "wallet").count == 1)
        store.openDetails(operation(database))
        #expect(store.presentedOperation == nil)
    }

    @Test(arguments: [SendTransactionNetworkStatus.confirmed, .failed])
    func groupDismissalPreservesTrackingAndLaterTerminalAnnouncement(status: SendTransactionNetworkStatus) async throws {
        let database = try WalletDatabase.temporary()
        _ = try await SendRecipientHistoryTestFixtures.seed(database)
        let receipt = SendRecipientHistoryTestFixtures.receipt(hash: "0x" + String(repeating: "9", count: 64))
        let pending = SendOperation(database: database,
            draft: SendEntryTestFixtures.draft(recipient: receipt.toAddress, amount: receipt.amount),
            walletAddress: receipt.fromAddress, nativeUnitUSDPrice: nil, statusReader: { _ in status })
        let sibling = operation(database, wallet: receipt.fromAddress)
        let other = operation(database, wallet: "other")
        let store = SendActivityStore(operations: [pending, sibling, other])
        let (outcomes, continuation) = AsyncStream<SendTransactionSubmissionOutcome>.makeStream()
        pending.start {
            var iterator = outcomes.makeAsyncIterator()
            return try #require(await iterator.next())
        }
        store.expandActivities(walletAddress: receipt.fromAddress)
        store.dismissActivities(walletAddress: receipt.fromAddress)
        #expect(store.expandedWalletAddress == nil)
        #expect(store.visibleOperations(walletAddress: receipt.fromAddress).isEmpty)
        #expect(!other.isAcknowledged)
        #expect(store.operations.count == 3)
        #expect(pending.isSubmitting)
        continuation.yield(.init(receipt: receipt, localTransactionID: nil, localPersistenceWarningCode: nil))
        continuation.finish()
        await pending.waitUntilSettled()
        #expect(pending.networkStatus == status)
        #expect(store.visibleOperations(walletAddress: receipt.fromAddress).map(\.id) == [pending.id])
        #expect(sibling.isAcknowledged)
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func nativeToolbarListScrollsAndSelectsTheExactTransaction(layout: NativeListTestLayout) async throws {
        let database = try WalletDatabase.temporary()
        // Compact title-and-amount rows can fit 12 items on iPad. Use enough
        // entries to overflow every fixture without imposing artificial heights.
        let operations = (0..<40).map { _ in operation(database) }
        let store = SendActivityStore(operations: operations)
        store.expandActivities(walletAddress: "wallet")
        let host = try NativeListTestHost(layout: layout) {
            WalletPendingActivityScreen(items: operations.reversed().map(WalletPendingActivityItem.operation),
                maximumHeight: layout.size.height * 0.65, onSelect: { item in
                    if case let .operation(operation) = item { store.openDetails(operation) }
                }, onClose: {})
                .frame(maxWidth: 560)
        }
        defer { host.close() }
        let list = try await host.list {
            $0.numberOfSections > 0 && $0.numberOfItems(inSection: 0) == operations.count
        }
        #expect(list.isScrollEnabled)
        try await host.selectRow(IndexPath(item: operations.count - 1, section: 0), in: list)
        #expect(store.presentedOperation?.id == operations.first?.id)
        #expect(store.expandedWalletAddress == "wallet")
        store.presentedOperation = nil
        try await host.selectRow(IndexPath(item: 0, section: 0), in: list)
        #expect(store.presentedOperation?.id == operations.last?.id)
    }

    @Test func collapsedAutomaticDismissalRemovesOnlyTheConfirmedOperation() async throws {
        let database = try WalletDatabase.temporary()
        let pending = operation(database)
        let confirmed = operation(database)
        confirm(confirmed)
        let store = SendActivityStore(operations: [pending, confirmed])
        let host = try NativeListTestHost {
            SendActivityGroupCapsule(store: store, walletAddress: "wallet", maximumHeight: 550)
        }
        defer { host.close() }
        try await Task.sleep(for: .milliseconds(3400))
        #expect(confirmed.isAcknowledged)
        #expect(!pending.isAcknowledged)
        #expect(store.visibleOperation(walletAddress: "wallet")?.id == pending.id)
    }

    private func operation(_ database: WalletDatabase, wallet: String = "wallet") -> SendOperation {
        SendOperation(database: database, draft: SendEntryTestFixtures.draft(), walletAddress: wallet,
                      nativeUnitUSDPrice: nil)
    }

    private func fail(_ operation: SendOperation) {
        operation.phase = .failed(.broadcastRejected(code: "rejected", message: "Rejected"))
    }

    private func confirm(_ operation: SendOperation) {
        let receipt = SendRecipientHistoryTestFixtures.receipt(hash: "0x" + String(repeating: "8", count: 64))
        operation.phase = .submitted(.init(receipt: receipt, localTransactionID: nil, localPersistenceWarningCode: nil))
        operation.applyMonitoredStatus(.confirmed)
    }
}

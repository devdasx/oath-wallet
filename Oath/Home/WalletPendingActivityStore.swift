import Foundation
import Observation

/// UI attention state only. Transactions and their statuses remain owned by WalletDatabase.
@MainActor @Observable
final class WalletPendingActivityStore {
    private(set) var walletID: String?
    private(set) var transactions: [WalletTransaction] = []
    private(set) var observationError: String?
    @ObservationIgnored private var previouslyPending = Set<String>()
    @ObservationIgnored private var reviewedFailures = Set<String>()
    @ObservationIgnored private var observationStartedAt = Date()
    var isPresented = false
    var selection: WalletPendingActivityItem?

    func observe(database: WalletDatabase, walletID: String?) async {
        prepareObservation(walletID: walletID)
        guard let walletID else { return }
        do {
            for try await snapshot in database.pendingActivity(walletID: walletID, since: observationStartedAt) {
                guard !Task.isCancelled, self.walletID == walletID else { return }
                apply(snapshot)
                observationError = nil
            }
        } catch is CancellationError {
            return
        } catch {
            // Keep the last known pending entries; never claim an empty queue after a read failure.
            observationError = SendTransactionSubmissionError.sanitizedErrorType(error)
        }
    }

    func prepareObservation(walletID: String?) {
        // Navigation can cancel and restart the Home task for the same wallet.
        // Keep unread failures and the observation boundary until the wallet changes.
        if self.walletID != walletID { reset(walletID: walletID) }
    }

    func reset(walletID: String?) {
        self.walletID = walletID
        observationStartedAt = Date()
        transactions = []
        previouslyPending = []
        reviewedFailures = []
        observationError = nil
        isPresented = false
        selection = nil
    }

    func apply(_ snapshot: [WalletTransaction]) {
        previouslyPending.formUnion(snapshot.filter { [.pending, .notFound, .replaced].contains($0.status) }.map(\.id))
        transactions = snapshot.filter {
            [.pending, .notFound].contains($0.status) || ([.failed, .canceled, .replaced].contains($0.status) && previouslyPending.contains($0.id)
                && !reviewedFailures.contains($0.id))
        }
        let retainedIDs = Set(transactions.map(\.id))
        previouslyPending.formIntersection(retainedIDs)
        reviewedFailures.formIntersection(Set(snapshot.map(\.id)))
    }

    func review(_ transaction: WalletTransaction) {
        guard [.failed, .canceled, .replaced].contains(transaction.status) else { return }
        reviewedFailures.insert(transaction.id)
        transactions.removeAll { $0.id == transaction.id }
    }

    func items(operations: [SendOperation], walletAddress: String) -> [WalletPendingActivityItem] {
        let owned = operations.filter { $0.walletAddress == walletAddress }
        // An operation's live terminal result takes precedence over a stale cached pending row.
        let ownedIdentities = Set(owned.compactMap { operation in
            operation.receipt.map { WalletPendingActivityItem.identity(network: $0.networkID, hash: $0.transactionHash) }
        })
        var result = owned.reversed().filter { operation in
            guard Self.includes(operation) else { return false }
            return switch operation.capsuleStatus {
            case .sending, .sent, .confirming, .warning: true
            case .failed: !operation.isAcknowledged
            case .confirmed: false
            }
        }.map(WalletPendingActivityItem.operation)
        var included = ownedIdentities
        for transaction in transactions {
            let identity = WalletPendingActivityItem.identity(network: transaction.metadata.blockchainIdentifier ?? "",
                                                            hash: transaction.metadata.transactionHash ?? transaction.id)
            if included.insert(identity).inserted { result.append(.transaction(transaction)) }
        }
        return result
    }

    static func includes(_ operation: SendOperation) -> Bool {
        let asset = operation.draft.asset
        guard !asset.isNative else { return true }
        guard asset.balance > 0, asset.fiatValue > 0,
              let text = operation.receipt?.amount ?? operation.draft.amount,
              let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return false }
        return WalletTransactionVisibilityPolicy.includesTokenTransfer(usdValue: amount * asset.fiatValue / asset.balance)
    }
}

enum WalletPendingActivityItem: Identifiable {
    case operation(SendOperation)
    case transaction(WalletTransaction)

    var id: String {
        switch self {
        case let .operation(operation): "send:" + operation.id.uuidString
        case let .transaction(transaction): "stored:" + transaction.id
        }
    }

    static func identity(network: String, hash: String) -> String {
        // EVM hashes are hexadecimal; case-sensitive base58/base64 identities stay unchanged.
        network + ":" + (hash.hasPrefix("0x") ? hash.lowercased() : hash)
    }
}

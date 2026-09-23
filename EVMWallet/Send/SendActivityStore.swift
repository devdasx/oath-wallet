import Foundation
import Observation

/// App-root ownership keeps sending and receipt monitoring alive after Send dismisses.
@MainActor @Observable
final class SendActivityStore {
    private(set) var operations: [SendOperation] = []
    @ObservationIgnored private var startedRequests: Set<UUID> = []
    var presentedOperation: SendOperation?
    var pendingRetry: SendOperation?
    var isActivityListPresented = false
    var hasDismissedSendSheet = false
    private(set) var expandedWalletAddress: String?

    init(operations: [SendOperation] = []) {
        self.operations = operations
    }

    func start(requestID: UUID, database: WalletDatabase, draft: SendDraft, authorization: SendTransactionAuthorization,
               walletAddress: String, nativeUnitUSDPrice: Decimal?,
               onTransactionBroadcast: @escaping (SendPostBroadcastRefreshRequest) -> Void) {
        guard startedRequests.insert(requestID).inserted else { return }
        let operation = SendOperation(database: database, draft: draft, walletAddress: walletAddress,
                                      nativeUnitUSDPrice: nativeUnitUSDPrice,
                                      onTransactionBroadcast: onTransactionBroadcast)
        operations.append(operation)
        hasDismissedSendSheet = false
        let service = SendTransactionSubmissionService(database: database)
        operation.start { try await service.submit(draft: draft, authorization: authorization) }
        // Only finished and acknowledged UI history is discarded. Pending sends keep their owner.
        operations.removeAll { $0.isAcknowledged && $0.networkStatus?.isTerminal == true }
    }

    func visibleOperation(walletAddress: String) -> SendOperation? {
        let eligible = operations.filter { $0.walletAddress == walletAddress && !$0.isAcknowledged }
        return eligible.last(where: { $0.receiptVisualStatus == .failed })
            ?? eligible.last(where: { $0.receiptVisualStatus == .confirmed })
            ?? eligible.first(where: \.isSubmitting) ?? eligible.last
    }

    /// Stable newest-first list; status updates do not reorder rows under a finger.
    func visibleOperations(walletAddress: String) -> [SendOperation] {
        operations.reversed().filter { $0.walletAddress == walletAddress && !$0.isAcknowledged }
    }

    func expandActivities(walletAddress: String) {
        guard !visibleOperations(walletAddress: walletAddress).isEmpty else { return }
        expandedWalletAddress = walletAddress
    }

    func collapseActivities() {
        expandedWalletAddress = nil
    }

    func openDetails(_ operation: SendOperation) {
        guard operations.contains(where: { $0.id == operation.id }) else { return }
        presentedOperation = operation
    }

    func dismissActivities(walletAddress: String) {
        for operation in visibleOperations(walletAddress: walletAddress) {
            operation.isAcknowledged = true
        }
        if expandedWalletAddress == walletAddress { collapseActivities() }
    }

    func finishDetails(_ operation: SendOperation) {
        // Closing during submission keeps the live capsule available.
        if !operation.isSubmitting { operation.isAcknowledged = true }
        collapseIfEmpty(walletAddress: operation.walletAddress)
        presentedOperation = nil
    }

    func dismissCapsule(_ operation: SendOperation) {
        // Explicit dismissal hides even a pending send. Its operation stays
        // retained so submission, monitoring, and persistence continue normally.
        // A later confirmation or definite failure renews its presentation once.
        operation.isAcknowledged = true
        collapseIfEmpty(walletAddress: operation.walletAddress)
    }

    private func collapseIfEmpty(walletAddress: String) {
        if expandedWalletAddress == walletAddress,
           visibleOperations(walletAddress: walletAddress).isEmpty { collapseActivities() }
    }

    func retry(_ operation: SendOperation) {
        guard operation.canRetry else { return }
        pendingRetry = operation
        presentedOperation = nil
    }

    func clear() {
        operations.forEach {
            $0.stopMonitoring()
            $0.capsuleDismissal.cancel()
        }
        isActivityListPresented = false
        operations.removeAll()
        presentedOperation = nil
        pendingRetry = nil
        collapseActivities()
    }
}

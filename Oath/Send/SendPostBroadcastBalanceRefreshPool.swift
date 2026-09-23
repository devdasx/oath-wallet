import Foundation

/// Concurrent sends in one wallet/network share the same fresh provider read.
/// All listeners receive progress; no completed result is cached as a new read.
actor SendPostBroadcastBalanceRefreshPool {
    static let shared = SendPostBroadcastBalanceRefreshPool()

    struct Key: Hashable, Sendable {
        let database: ObjectIdentifier
        let walletID: String
        let networkID: String
    }
    private struct Job {
        let id: UUID
        let task: Task<Void, Never>
        var subscribers: [UUID: Subscriber]
    }
    private struct Subscriber {
        let completion: CheckedContinuation<WalletChainSyncOutcome, Never>
        let progress: WalletSyncProgressHandler?
    }
    private var jobs: [Key: Job] = [:]

    func refresh(database: WalletDatabase, walletID: String, receipt: SendTransactionReceipt,
                 afterInFlightRead: Bool = false,
                 onProgress: WalletSyncProgressHandler?) async -> WalletChainSyncOutcome {
        let key = Key(database: ObjectIdentifier(database), walletID: walletID, networkID: receipt.networkID)
        // A terminal follow-up cannot reuse a read started while its outcome
        // was still pending. Finish that read, then join/start a fresh one.
        if afterInFlightRead, let job = jobs[key] { await job.task.value }
        return await refresh(key: key, onProgress: onProgress) { progress in
            await SendPostBroadcastChainRefreshService(database: database).refresh(
                walletID: walletID, receipt: receipt, onProgress: progress)
        }
    }

    func refresh(key: Key, onProgress: WalletSyncProgressHandler?,
                 operation: @escaping @Sendable (@escaping WalletSyncProgressHandler) async -> WalletChainSyncOutcome)
        async -> WalletChainSyncOutcome {
        let subscriberID = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return .cancelled(.evm) }
            return await withCheckedContinuation { continuation in
                let subscriber = Subscriber(completion: continuation, progress: onProgress)
                if jobs[key] != nil {
                    jobs[key]?.subscribers[subscriberID] = subscriber
                } else {
                    let jobID = UUID()
                    let task = Task {
                        let result = await operation { event in await self.publish(event, key: key, jobID: jobID) }
                        complete(result, key: key, jobID: jobID)
                    }
                    jobs[key] = Job(id: jobID, task: task, subscribers: [subscriberID: subscriber])
                }
            }
        } onCancel: {
            Task { await self.cancel(subscriberID, key: key) }
        }
    }

    private func publish(_ event: WalletSyncProgressEvent, key: Key, jobID: UUID) async {
        guard let job = jobs[key], job.id == jobID else { return }
        let listeners = job.subscribers.values.compactMap(\.progress)
        for listener in listeners { await listener(event) }
    }

    private func complete(_ outcome: WalletChainSyncOutcome, key: Key, jobID: UUID) {
        guard let job = jobs[key], job.id == jobID else { return }
        jobs[key] = nil
        for subscriber in job.subscribers.values { subscriber.completion.resume(returning: outcome) }
    }

    private func cancel(_ subscriberID: UUID, key: Key) {
        jobs[key]?.subscribers.removeValue(forKey: subscriberID)?.completion.resume(returning: .cancelled(.evm))
        guard let job = jobs[key], job.subscribers.isEmpty else { return }
        jobs[key] = nil
        job.task.cancel()
    }
}

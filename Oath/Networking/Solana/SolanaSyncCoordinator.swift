import Foundation

/// Shares a wallet refresh across entry points, including its persistence work.
/// No completed snapshot is cached here. A post-send refresh drains cancelled
/// older work before reading again, so an old save can never land after it.
actor SolanaSyncCoordinator {
    static let shared = SolanaSyncCoordinator()

    struct Key: Hashable, Sendable {
        let databaseID: ObjectIdentifier
        let walletID: String
    }

    typealias Operation = @Sendable (
        @escaping WalletSyncProgressHandler
    ) async -> WalletChainSyncOutcome

    private struct Waiter {
        let continuation: CheckedContinuation<WalletChainSyncOutcome, Never>
        let onProgress: WalletSyncProgressHandler?
    }

    private struct Entry {
        let key: Key
        let task: Task<WalletChainSyncOutcome, Never>
        var waiters: [UUID: Waiter]
        var latestProgress: WalletSyncProgressEvent?
    }

    private var current: [Key: UUID] = [:]
    private var entries: [UUID: Entry] = [:]

    func sync(
        key: Key,
        requiresFresh: Bool = false,
        onProgress: WalletSyncProgressHandler? = nil,
        operation: @escaping Operation
    ) async -> WalletChainSyncOutcome {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled(.solana))
                    return
                }
                let waiter = Waiter(continuation: continuation, onProgress: onProgress)
                let previousID = current[key]
                let previous = previousID.flatMap { entries[$0] }
                if !requiresFresh, let previousID, let previous, !previous.task.isCancelled {
                    entries[previousID]?.waiters[waiterID] = waiter
                    if let event = previous.latestProgress {
                        Task { await self.deliver(event, entryID: previousID, waiterID: waiterID) }
                    }
                    return
                }

                previous?.task.cancel()
                let entryID = UUID()
                let previousTask = previous?.task
                let task = Task {
                    // Cancellation alone cannot stop an already submitted DB
                    // write. Waiting for the previous operation orders writes.
                    if let previousTask { _ = await previousTask.value }
                    let outcome: WalletChainSyncOutcome
                    if Task.isCancelled {
                        outcome = .cancelled(.solana)
                    } else {
                        outcome = await operation { event in
                            await self.publish(event, entryID: entryID)
                        }
                    }
                    self.finish(entryID: entryID, outcome: outcome)
                    return outcome
                }
                entries[entryID] = Entry(key: key, task: task, waiters: [waiterID: waiter])
                current[key] = entryID
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID) }
        }
    }

    private func cancel(waiterID: UUID) {
        for entryID in Array(entries.keys) {
            guard let waiter = entries[entryID]?.waiters.removeValue(forKey: waiterID) else { continue }
            waiter.continuation.resume(returning: .cancelled(.solana))
            if entries[entryID]?.waiters.isEmpty == true {
                entries[entryID]?.task.cancel()
            }
            return
        }
    }

    private func publish(_ event: WalletSyncProgressEvent, entryID: UUID) async {
        guard let entry = entries[entryID], current[entry.key] == entryID,
              !entry.task.isCancelled else { return }
        entries[entryID]?.latestProgress = event
        for waiterID in entry.waiters.keys {
            await deliver(event, entryID: entryID, waiterID: waiterID)
        }
    }

    private func deliver(_ event: WalletSyncProgressEvent, entryID: UUID, waiterID: UUID) async {
        guard let entry = entries[entryID], current[entry.key] == entryID,
              !entry.task.isCancelled else { return }
        await entry.waiters[waiterID]?.onProgress?(event)
    }

    private func finish(entryID: UUID, outcome: WalletChainSyncOutcome) {
        guard let entry = entries.removeValue(forKey: entryID) else { return }
        if current[entry.key] == entryID { current[entry.key] = nil }
        for waiter in entry.waiters.values { waiter.continuation.resume(returning: outcome) }
    }
}

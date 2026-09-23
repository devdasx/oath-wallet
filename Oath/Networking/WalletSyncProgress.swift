import Foundation

enum WalletPrivateScanKind: Hashable, Sendable {
    case bitcoinSilentPayments
}

struct WalletPrivateScanLiveProgress: Equatable, Sendable {
    let walletID: String
    let kind: WalletPrivateScanKind
    let startHeight: Int64
    let durableHeight: Int64
    let currentHeight: Int64
    let targetHeight: Int64
    let isCurrentHeightEstimated: Bool

    var completionFraction: Double? {
        guard targetHeight > startHeight else { return nil }
        let completed = max(
            0,
            min(currentHeight, targetHeight) - startHeight
        )
        return Double(completed) / Double(targetHeight - startHeight)
    }
}

/// Process-local delivery of scanner progress that is newer than the last
/// atomic GRDB checkpoint. This is presentation state only: callers must never
/// use `currentHeight` as a restart cursor. `durableHeight` remains the exact
/// highest contiguous height whose wallet cache/results were committed.
final class WalletPrivateScanLiveProgressCenter: @unchecked Sendable {
    static let shared = WalletPrivateScanLiveProgressCenter()

    private struct Key: Hashable, Sendable {
        let walletID: String
        let kind: WalletPrivateScanKind
    }

    private struct Entry {
        let token: UUID
        var progress: WalletPrivateScanLiveProgress
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var observers: [
        Key: [UUID: AsyncStream<WalletPrivateScanLiveProgress?>.Continuation]
    ] = [:]

    @discardableResult
    func begin(
        walletID: String,
        kind: WalletPrivateScanKind,
        startHeight: Int64,
        durableHeight: Int64,
        targetHeight: Int64,
        isCurrentHeightEstimated: Bool
    ) -> UUID {
        let token = UUID()
        let key = Key(walletID: walletID, kind: kind)
        let normalizedStart = max(0, startHeight)
        let normalizedDurable = max(normalizedStart, durableHeight)
        let normalizedTarget = max(normalizedDurable, targetHeight)
        let publication = withLock {
            let previous = entries[key]?.progress
            let mergedStart = min(
                previous?.startHeight ?? normalizedStart,
                normalizedStart
            )
            let mergedDurable = max(
                previous?.durableHeight ?? normalizedDurable,
                normalizedDurable,
                mergedStart
            )
            let mergedTarget = max(
                previous?.targetHeight ?? normalizedTarget,
                normalizedTarget,
                mergedDurable
            )
            let mergedCurrent = min(
                mergedTarget,
                max(
                    previous?.currentHeight ?? mergedDurable,
                    mergedDurable
                )
            )
            let progress = WalletPrivateScanLiveProgress(
                walletID: walletID,
                kind: kind,
                startHeight: mergedStart,
                durableHeight: mergedDurable,
                currentHeight: mergedCurrent,
                targetHeight: mergedTarget,
                isCurrentHeightEstimated: isCurrentHeightEstimated
            )
            entries[key] = Entry(token: token, progress: progress)
            return (progress, observerContinuations(for: key))
        }
        publication.1.forEach { $0.yield(publication.0) }
        return token
    }

    func update(
        walletID: String,
        kind: WalletPrivateScanKind,
        token: UUID,
        currentHeight: Int64,
        targetHeight: Int64
    ) {
        let key = Key(walletID: walletID, kind: kind)
        let publication: (
            WalletPrivateScanLiveProgress,
            [AsyncStream<WalletPrivateScanLiveProgress?>.Continuation]
        )? = withLock {
            guard var entry = entries[key], entry.token == token else {
                return nil
            }
            let target = max(
                entry.progress.targetHeight,
                targetHeight,
                entry.progress.durableHeight
            )
            let current = min(
                target,
                max(entry.progress.currentHeight, currentHeight)
            )
            guard current != entry.progress.currentHeight
                    || target != entry.progress.targetHeight else {
                return nil
            }
            entry.progress = WalletPrivateScanLiveProgress(
                walletID: entry.progress.walletID,
                kind: entry.progress.kind,
                startHeight: entry.progress.startHeight,
                durableHeight: entry.progress.durableHeight,
                currentHeight: current,
                targetHeight: target,
                isCurrentHeightEstimated:
                    entry.progress.isCurrentHeightEstimated
            )
            entries[key] = entry
            return (
                entry.progress,
                observerContinuations(for: key)
            )
        }
        guard let publication else { return }
        publication.1.forEach { $0.yield(publication.0) }
    }

    func markDurable(
        walletID: String,
        kind: WalletPrivateScanKind,
        token: UUID,
        height: Int64
    ) {
        let key = Key(walletID: walletID, kind: kind)
        let publication: (
            WalletPrivateScanLiveProgress,
            [AsyncStream<WalletPrivateScanLiveProgress?>.Continuation]
        )? = withLock {
            guard var entry = entries[key], entry.token == token else {
                return nil
            }
            let durable = min(
                entry.progress.targetHeight,
                max(entry.progress.durableHeight, height)
            )
            guard durable != entry.progress.durableHeight else { return nil }
            entry.progress = WalletPrivateScanLiveProgress(
                walletID: entry.progress.walletID,
                kind: entry.progress.kind,
                startHeight: entry.progress.startHeight,
                durableHeight: durable,
                currentHeight: max(entry.progress.currentHeight, durable),
                targetHeight: entry.progress.targetHeight,
                isCurrentHeightEstimated:
                    entry.progress.isCurrentHeightEstimated
            )
            entries[key] = entry
            return (
                entry.progress,
                observerContinuations(for: key)
            )
        }
        guard let publication else { return }
        publication.1.forEach { $0.yield(publication.0) }
    }

    func finish(
        walletID: String,
        kind: WalletPrivateScanKind,
        token: UUID
    ) {
        let key = Key(walletID: walletID, kind: kind)
        let continuations: [
            AsyncStream<WalletPrivateScanLiveProgress?>.Continuation
        ] = withLock {
            guard entries[key]?.token == token else { return [] }
            entries.removeValue(forKey: key)
            return observerContinuations(for: key)
        }
        continuations.forEach { $0.yield(nil) }
    }

    func clear(walletID: String, kind: WalletPrivateScanKind) {
        let key = Key(walletID: walletID, kind: kind)
        let continuations: [
            AsyncStream<WalletPrivateScanLiveProgress?>.Continuation
        ] = withLock {
            guard entries.removeValue(forKey: key) != nil else { return [] }
            return observerContinuations(for: key)
        }
        continuations.forEach { $0.yield(nil) }
    }

    func observation(
        walletID: String,
        kind: WalletPrivateScanKind
    ) -> AsyncStream<WalletPrivateScanLiveProgress?> {
        let key = Key(walletID: walletID, kind: kind)
        let observerID = UUID()
        let pair = AsyncStream<WalletPrivateScanLiveProgress?>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        pair.continuation.onTermination = { [weak self] _ in
            self?.removeObserver(key: key, id: observerID)
        }
        let current = withLock {
            observers[key, default: [:]][observerID] = pair.continuation
            return entries[key]?.progress
        }
        pair.continuation.yield(current)
        return pair.stream
    }

    private func removeObserver(key: Key, id: UUID) {
        withLock {
            observers[key]?[id] = nil
            if observers[key]?.isEmpty == true {
                observers[key] = nil
            }
        }
    }

    private func observerContinuations(
        for key: Key
    ) -> [AsyncStream<WalletPrivateScanLiveProgress?>.Continuation] {
        observers[key].map { Array($0.values) } ?? []
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

struct WalletSyncProgressEvent: Equatable, Sendable {
    enum Stage: String, Sendable {
        case balancesPersisted = "balances_persisted"
        case transactionsPersisted = "transactions_persisted"
        case snapshotPersisted = "snapshot_persisted"
        case valuationPersisted = "valuation_persisted"
    }

    let source: WalletSyncSource
    let networkID: String?
    let stage: Stage

    init(
        source: WalletSyncSource,
        networkID: String? = nil,
        stage: Stage = .balancesPersisted
    ) {
        self.source = source
        self.networkID = networkID
        self.stage = stage
    }
}

typealias WalletSyncProgressHandler =
    @MainActor @Sendable (WalletSyncProgressEvent) async -> Void

/// Publishes one atomic completion event after a provider snapshot has stored
/// both portfolio and activity data. Balance-only progress is emitted by each
/// service at the earlier balance persistence checkpoint, so publishing a
/// second balance event here would cause a redundant database read and home
/// presentation revision.
func publishWalletSyncDatasets(
    source: WalletSyncSource,
    networkID: String? = nil,
    onProgress: WalletSyncProgressHandler?
) async {
    if let database = try? WalletDatabaseRuntime.require() {
        AssetCatalogSyncService.schedule(database: database)
    }
    guard let onProgress else { return }
    await onProgress(
        WalletSyncProgressEvent(
            source: source,
            networkID: networkID,
            stage: .snapshotPersisted
        )
    )
}

actor WalletSyncPersistenceTracker {
    private(set) var didPersistData = false

    func markPersisted() {
        didPersistData = true
        if let database = try? WalletDatabaseRuntime.require() {
            AssetCatalogSyncService.schedule(database: database)
        }
    }
}

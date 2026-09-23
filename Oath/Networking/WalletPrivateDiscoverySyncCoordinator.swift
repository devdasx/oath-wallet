import Foundation

/// Runs private-key discovery for every eligible wallet, independently of the
/// wallet currently selected in the interface.
actor WalletPrivateDiscoverySyncCoordinator {
    typealias BitcoinRunner = @Sendable (String) async -> Bool

    private struct BitcoinDrainOperation: Sendable {
        let id: UUID
        let task: Task<Bool, Never>
    }

    static let shared = WalletPrivateDiscoverySyncCoordinator()

    private let maximumConcurrentBitcoinWallets: Int
    private let bitcoinRunner: BitcoinRunner

    private var database: WalletDatabase?
    private var observationTask: Task<Void, Never>?
    private var eligibleWalletIDs: Set<String> = []
    private var pendingBitcoinWalletIDs: Set<String> = []
    private var activeBitcoinWalletIDs: Set<String> = []
    private var bitcoinDrainOperation: BitcoinDrainOperation?

    init(
        maximumConcurrentBitcoinWallets: Int = 2,
        bitcoinRunner: @escaping BitcoinRunner = { walletID in
            await BitcoinHDWalletSyncService.shared
                .refreshSilentPaymentBalance(walletID: walletID)
        }
    ) {
        self.maximumConcurrentBitcoinWallets = max(
            1,
            maximumConcurrentBitcoinWallets
        )
        self.bitcoinRunner = bitcoinRunner
    }

    func start(database: WalletDatabase) {
        guard self.database !== database else { return }
        observationTask?.cancel()
        self.database = database

        let values = database.privateDiscoveryWalletIDsObservation()
        observationTask = Task(priority: .utility) { [weak self] in
            do {
                for try await walletIDs in values {
                    guard !Task.isCancelled else { return }
                    await self?.walletIDsDidChange(
                        walletIDs,
                        forceRefresh: false
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    /// Explicit lifecycle trigger used when the app becomes active and by the
    /// system background-processing task. Database observation remains the
    /// source of truth for wallet creation, import, restoration, and removal.
    @discardableResult
    func synchronizeAllWallets() async -> Bool {
        await synchronizeAllWalletsNow()
    }

    /// Keeps a system background-processing task alive until private
    /// discovery finishes or iOS expires the enclosing task.
    @discardableResult
    func synchronizeAllWalletsForBackgroundProcessing() async -> Bool {
        await synchronizeAllWalletsNow()
    }

    private func synchronizeAllWalletsNow() async -> Bool {
        guard let database else { return false }
        do {
            let walletIDs = try await database.privateDiscoveryWalletIDs()
            await walletIDsDidChange(walletIDs, forceRefresh: true)
            return await waitForBitcoinDrain()
        } catch is CancellationError {
            return false
        } catch {
            return false
        }
    }

    private func walletIDsDidChange(
        _ walletIDs: [String],
        forceRefresh: Bool
    ) async {
        let normalizedWalletIDs = Array(Set(walletIDs)).sorted()
        let normalizedSet = Set(normalizedWalletIDs)
        let previousWalletIDs = eligibleWalletIDs
        let drainWasActive = bitcoinDrainOperation != nil
        eligibleWalletIDs = normalizedSet
        pendingBitcoinWalletIDs.formIntersection(normalizedSet)

        let newlyEligibleWalletIDs = normalizedSet.subtracting(
            previousWalletIDs
        )
        let requestedBitcoinWalletIDs: Set<String>
        if forceRefresh, !drainWasActive {
            requestedBitcoinWalletIDs = normalizedSet
        } else {
            requestedBitcoinWalletIDs = newlyEligibleWalletIDs
        }
        for walletID in requestedBitcoinWalletIDs
        where !activeBitcoinWalletIDs.contains(walletID) {
            pendingBitcoinWalletIDs.insert(walletID)
        }
        startBitcoinDrainIfNeeded()
    }

    private func startBitcoinDrainIfNeeded() {
        guard bitcoinDrainOperation == nil,
              !pendingBitcoinWalletIDs.isEmpty else { return }
        let operationID = UUID()
        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return false }
            return await self.drainBitcoinWallets(
                operationID: operationID
            )
        }
        bitcoinDrainOperation = BitcoinDrainOperation(
            id: operationID,
            task: task
        )
    }

    private func drainBitcoinWallets(operationID: UUID) async -> Bool {
        var allSucceeded = true
        while !Task.isCancelled {
            guard bitcoinDrainOperation?.id == operationID else {
                return false
            }
            let batch = pendingBitcoinWalletIDs.sorted().prefix(
                maximumConcurrentBitcoinWallets
            )
            guard !batch.isEmpty else {
                finishBitcoinDrain(operationID: operationID)
                return allSucceeded
            }
            let walletIDs = Array(batch)
            pendingBitcoinWalletIDs.subtract(walletIDs)
            activeBitcoinWalletIDs.formUnion(walletIDs)

            let results = await withTaskGroup(of: Bool.self) { group in
                for walletID in walletIDs {
                    group.addTask { [bitcoinRunner] in
                        await bitcoinRunner(walletID)
                    }
                }
                var outcomes: [Bool] = []
                for await outcome in group {
                    outcomes.append(outcome)
                }
                return outcomes
            }
            activeBitcoinWalletIDs.subtract(walletIDs)
            allSucceeded = allSucceeded && results.allSatisfy { $0 }

            // A removed wallet may have completed while its request was in
            // flight. Never put it back into a later batch.
            pendingBitcoinWalletIDs.formIntersection(eligibleWalletIDs)
        }
        finishBitcoinDrain(operationID: operationID)
        return false
    }

    private func waitForBitcoinDrain() async -> Bool {
        var allSucceeded = true
        while let operation = bitcoinDrainOperation {
            allSucceeded = await operation.task.value && allSucceeded
            guard !Task.isCancelled else { return false }
        }
        return allSucceeded
    }

    private func finishBitcoinDrain(operationID: UUID) {
        guard bitcoinDrainOperation?.id == operationID else { return }
        bitcoinDrainOperation = nil
        if !pendingBitcoinWalletIDs.isEmpty {
            startBitcoinDrainIfNeeded()
        }
    }
}

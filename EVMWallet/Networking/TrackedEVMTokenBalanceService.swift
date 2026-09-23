import Foundation

struct TrackedEVMTokenHoldingID: Hashable, Sendable {
    let accountID: String
    let assetID: String
}

struct TrackedEVMTokenBalanceTarget: Hashable, Sendable {
    let holdingID: TrackedEVMTokenHoldingID
    let networkID: String
    let expectedChainID: Int
    let ownerAddress: String
    let contractAddress: String
    let decimals: Int
}

struct TrackedEVMTokenBalanceUpdate: Equatable, Sendable {
    let holdingID: TrackedEVMTokenHoldingID
    let balanceText: String
    let balanceAtomic: String
}

struct TrackedEVMTokenBalanceBatch: Equatable, Sendable {
    let updates: [TrackedEVMTokenBalanceUpdate]
    let failedHoldingIDs: Set<TrackedEVMTokenHoldingID>

    static let empty = TrackedEVMTokenBalanceBatch(
        updates: [],
        failedHoldingIDs: []
    )
}

protocol TrackedEVMTokenBalanceRPC: Sendable {
    func chainID() async throws -> String

    func tokenBalance(
        ownerAddress: String,
        contractAddress: String
    ) async throws -> String
}

extension SendEVMRPCClient: TrackedEVMTokenBalanceRPC {}

struct TrackedEVMTokenBalanceService: Sendable {
    typealias ClientFactory = @Sendable (
        _ networkID: String
    ) throws -> any TrackedEVMTokenBalanceRPC

    private enum QueryResult: Sendable {
        case updated(TrackedEVMTokenBalanceUpdate)
        case failed(TrackedEVMTokenBalanceTarget)
    }

    private struct NetworkBatch: Sendable {
        let updates: [TrackedEVMTokenBalanceUpdate]
        let failedHoldingIDs: Set<TrackedEVMTokenHoldingID>
    }

    private struct QueryPass: Sendable {
        let updates: [TrackedEVMTokenBalanceUpdate]
        let failedTargets: [TrackedEVMTokenBalanceTarget]
    }

    private let clientFactory: ClientFactory
    private let chainIDCache: TrackedEVMChainIDCache
    private let maximumConcurrentNetworks: Int
    private let maximumConcurrentTokensPerNetwork: Int

    init(
        maximumConcurrentNetworks: Int = 4,
        maximumConcurrentTokensPerNetwork: Int = 6
    ) {
        self.init(
            maximumConcurrentNetworks: maximumConcurrentNetworks,
            maximumConcurrentTokensPerNetwork:
                maximumConcurrentTokensPerNetwork,
            chainIDCache: .shared,
            clientFactory: {
                try SendEVMRPCClient(networkID: $0)
            }
        )
    }

    init(
        maximumConcurrentNetworks: Int = 4,
        maximumConcurrentTokensPerNetwork: Int = 6,
        chainIDCache: TrackedEVMChainIDCache = TrackedEVMChainIDCache(),
        clientFactory: @escaping ClientFactory
    ) {
        self.maximumConcurrentNetworks = max(
            1,
            maximumConcurrentNetworks
        )
        self.maximumConcurrentTokensPerNetwork = max(
            1,
            maximumConcurrentTokensPerNetwork
        )
        self.chainIDCache = chainIDCache
        self.clientFactory = clientFactory
    }

    func loadBalances(
        for targets: [TrackedEVMTokenBalanceTarget]
    ) async throws -> TrackedEVMTokenBalanceBatch {
        guard !targets.isEmpty else {
            return .empty
        }
        try Task.checkCancellation()

        let groupedTargets = Dictionary(
            grouping: targets,
            by: \.networkID
        )
        let networkGroups = groupedTargets
            .map { networkID, targets in
                (
                    networkID: networkID,
                    targets: targets.sorted(by: Self.targetOrder)
                )
            }
            .sorted { $0.networkID < $1.networkID }

        var updates: [TrackedEVMTokenBalanceUpdate] = []
        var failures = Set<TrackedEVMTokenHoldingID>()
        try await withThrowingTaskGroup(
            of: NetworkBatch.self
        ) { group in
            let initialCount = min(
                maximumConcurrentNetworks,
                networkGroups.count
            )
            for index in 0..<initialCount {
                let networkGroup = networkGroups[index]
                group.addTask {
                    try await queryNetwork(
                        networkID: networkGroup.networkID,
                        targets: networkGroup.targets
                    )
                }
            }

            var nextIndex = initialCount
            while let batch = try await group.next() {
                updates.append(contentsOf: batch.updates)
                failures.formUnion(batch.failedHoldingIDs)
                if nextIndex < networkGroups.count {
                    let networkGroup = networkGroups[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        try await queryNetwork(
                            networkID: networkGroup.networkID,
                            targets: networkGroup.targets
                        )
                    }
                }
            }
        }

        return TrackedEVMTokenBalanceBatch(
            updates: updates.sorted(by: Self.updateOrder),
            failedHoldingIDs: failures
        )
    }

    private func queryNetwork(
        networkID: String,
        targets: [TrackedEVMTokenBalanceTarget]
    ) async throws -> NetworkBatch {
        guard let expectedChainID = targets.first?.expectedChainID else {
            return NetworkBatch(updates: [], failedHoldingIDs: [])
        }
        guard targets.allSatisfy({
            $0.networkID == networkID
                && $0.expectedChainID == expectedChainID
        }) else {
            return failedBatch(targets)
        }

        let client: any TrackedEVMTokenBalanceRPC
        do {
            client = try clientFactory(networkID)
            let chainIDHex = try await chainIDCache.value(
                for: networkID
            ) {
                try await client.chainID()
            }
            let chainID = try SendAtomicAmount.decimalFromHexQuantity(
                chainIDHex
            )
            guard chainID == String(expectedChainID) else {
                return failedBatch(targets)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return failedBatch(targets)
        }

        let firstPass = try await queryTargets(
            targets,
            client: client,
            maximumConcurrency: maximumConcurrentTokensPerNetwork
        )
        guard !firstPass.failedTargets.isEmpty else {
            return NetworkBatch(
                updates: firstPass.updates,
                failedHoldingIDs: []
            )
        }

        // Public RPCs occasionally shed individual eth_call requests during
        // a large catalog refresh. Retry only failed contracts, with lower
        // pressure, rather than replaying successful reads or accepting a
        // partial zeroed snapshot.
        let retryPass = try await queryTargets(
            firstPass.failedTargets,
            client: client,
            maximumConcurrency: min(
                2,
                maximumConcurrentTokensPerNetwork
            )
        )
        guard !retryPass.failedTargets.isEmpty else {
            return NetworkBatch(
                updates: firstPass.updates + retryPass.updates,
                failedHoldingIDs: []
            )
        }

        // A final serialized pass prevents a provider that is already under
        // batch pressure from dropping the same otherwise-valid contract a
        // second time. Only the still-failed subset reaches this pass.
        let finalPass = try await queryTargets(
            retryPass.failedTargets,
            client: client,
            maximumConcurrency: 1
        )
        return NetworkBatch(
            updates: firstPass.updates
                + retryPass.updates
                + finalPass.updates,
            failedHoldingIDs: Set(
                finalPass.failedTargets.map(\.holdingID)
            )
        )
    }

    private func queryTargets(
        _ targets: [TrackedEVMTokenBalanceTarget],
        client: any TrackedEVMTokenBalanceRPC,
        maximumConcurrency: Int
    ) async throws -> QueryPass {
        var updates: [TrackedEVMTokenBalanceUpdate] = []
        var failures: [TrackedEVMTokenBalanceTarget] = []
        try await withThrowingTaskGroup(
            of: QueryResult.self
        ) { group in
            let initialCount = min(
                maximumConcurrency,
                targets.count
            )
            for index in 0..<initialCount {
                let target = targets[index]
                group.addTask {
                    try await queryBalance(
                        target: target,
                        client: client
                    )
                }
            }

            var nextIndex = initialCount
            while let result = try await group.next() {
                switch result {
                case let .updated(update):
                    updates.append(update)
                case let .failed(target):
                    failures.append(target)
                }
                if nextIndex < targets.count {
                    let target = targets[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        try await queryBalance(
                            target: target,
                            client: client
                        )
                    }
                }
            }
        }

        return QueryPass(
            updates: updates,
            failedTargets: failures.sorted(by: Self.targetOrder)
        )
    }

    private func queryBalance(
        target: TrackedEVMTokenBalanceTarget,
        client: any TrackedEVMTokenBalanceRPC
    ) async throws -> QueryResult {
        do {
            let balanceHex = try await client.tokenBalance(
                ownerAddress: target.ownerAddress,
                contractAddress: target.contractAddress
            )
            let atomicBalance = try SendAtomicAmount
                .decimalFromABIUnsignedInteger(balanceHex)
            let amount = try AnkrTokenAmount(
                rawInteger: atomicBalance,
                normalizedValue: nil,
                decimals: target.decimals
            )
            return .updated(
                TrackedEVMTokenBalanceUpdate(
                    holdingID: target.holdingID,
                    balanceText: amount.exactMagnitudeText,
                    balanceAtomic: atomicBalance
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed(target)
        }
    }

    private func failedBatch(
        _ targets: [TrackedEVMTokenBalanceTarget]
    ) -> NetworkBatch {
        NetworkBatch(
            updates: [],
            failedHoldingIDs: Set(targets.map(\.holdingID))
        )
    }

    private static func targetOrder(
        _ lhs: TrackedEVMTokenBalanceTarget,
        _ rhs: TrackedEVMTokenBalanceTarget
    ) -> Bool {
        if lhs.holdingID.accountID != rhs.holdingID.accountID {
            return lhs.holdingID.accountID < rhs.holdingID.accountID
        }
        return lhs.holdingID.assetID < rhs.holdingID.assetID
    }

    private static func updateOrder(
        _ lhs: TrackedEVMTokenBalanceUpdate,
        _ rhs: TrackedEVMTokenBalanceUpdate
    ) -> Bool {
        if lhs.holdingID.accountID != rhs.holdingID.accountID {
            return lhs.holdingID.accountID < rhs.holdingID.accountID
        }
        return lhs.holdingID.assetID < rhs.holdingID.assetID
    }
}

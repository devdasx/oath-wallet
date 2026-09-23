import Foundation

extension AnkrAPIClient {
    /// Routes each history stream to the provider that indexes the chain:
    /// ANKR Advanced for its verified mainnets, Blockscout for the rest.
    func tokenTransferOutcome(
        address: String,
        chains: [String],
        fromTimestamp: Int64?
    ) async throws -> AnkrTokenTransferLoadOutcome {
        let ankrChains = chains.filter(Self.usesAdvancedHistory)
        let blockscoutChains = chains.filter(Self.usesBlockscoutHistory)
        async let ankrLoad: AnkrTokenTransferLoadOutcome? = ankrChains.isEmpty
            ? nil
            : try await ankrTokenTransferOutcome(
                address: address,
                chains: ankrChains,
                fromTimestamp: fromTimestamp
            )
        let blockscout = await blockscoutTokenTransferOutcome(
            address: address,
            chains: blockscoutChains,
            fromTimestamp: fromTimestamp
        )
        let ankr = try await ankrLoad
        try Task.checkCancellation()
        return AnkrTokenTransferLoadOutcome(
            result: AnkrTokenTransferResult(
                transfers: (ankr?.result.transfers ?? [])
                    + blockscout.result.transfers,
                nextPageToken: nil
            ),
            failure: ankr?.failure ?? blockscout.failure
        )
    }

    func nativeTransactionOutcome(
        address: String,
        chains: [String],
        fromTimestamp: Int64?
    ) async throws -> AnkrNativeTransactionLoadOutcome {
        let ankrChains = chains.filter(Self.usesAdvancedHistory)
        let blockscoutChains = chains.filter(Self.usesBlockscoutHistory)
        async let ankrLoad: AnkrNativeTransactionLoadOutcome? = ankrChains.isEmpty
            ? nil
            : try await ankrNativeTransactionOutcome(
                address: address,
                chains: ankrChains,
                fromTimestamp: fromTimestamp
            )
        let blockscout = await blockscoutNativeTransactionOutcome(
            address: address,
            chains: blockscoutChains,
            fromTimestamp: fromTimestamp
        )
        let ankr = try await ankrLoad
        try Task.checkCancellation()
        return AnkrNativeTransactionLoadOutcome(
            result: AnkrRawTransactionResult(
                transactions: (ankr?.result.transactions ?? [])
                    + blockscout.result.transactions,
                nextPageToken: nil
            ),
            failure: ankr?.failure ?? blockscout.failure
        )
    }

    private func blockscoutTokenTransferOutcome(
        address: String,
        chains: [String],
        fromTimestamp: Int64?
    ) async -> AnkrTokenTransferLoadOutcome {
        var transfers: [AnkrTokenTransfer] = []
        var failure: WalletChainSyncFailure?
        for networkID in chains {
            guard let client = blockscoutHistoryClient,
                  client.networkID == networkID
            else {
                failure = failure ?? WalletChainSyncFailure(
                    source: .evm,
                    stage: .historyEnrichment,
                    error: BlockscoutHistoryError.configurationUnavailable,
                    networkID: networkID
                )
                continue
            }
            do {
                let page = try await client.tokenTransfers(
                    address: address,
                    fromTimestamp: fromTimestamp
                )
                transfers.append(contentsOf: page.transfers)
            } catch {
                failure = failure ?? WalletChainSyncFailure(
                    source: .evm,
                    stage: .historyEnrichment,
                    error: error,
                    networkID: networkID
                )
            }
        }
        return AnkrTokenTransferLoadOutcome(
            result: AnkrTokenTransferResult(
                transfers: transfers,
                nextPageToken: nil
            ),
            failure: failure
        )
    }

    private func blockscoutNativeTransactionOutcome(
        address: String,
        chains: [String],
        fromTimestamp: Int64?
    ) async -> AnkrNativeTransactionLoadOutcome {
        var transactions: [AnkrRawTransaction] = []
        var failure: WalletChainSyncFailure?
        for networkID in chains {
            guard let client = blockscoutHistoryClient,
                  client.networkID == networkID
            else {
                failure = failure ?? WalletChainSyncFailure(
                    source: .evm,
                    stage: .historyEnrichment,
                    error: BlockscoutHistoryError.configurationUnavailable,
                    networkID: networkID
                )
                continue
            }
            do {
                let page = try await client.nativeTransactions(
                    address: address,
                    fromTimestamp: fromTimestamp
                )
                transactions.append(contentsOf: page.transactions)
            } catch {
                failure = failure ?? WalletChainSyncFailure(
                    source: .evm,
                    stage: .historyEnrichment,
                    error: error,
                    networkID: networkID
                )
            }
        }
        return AnkrNativeTransactionLoadOutcome(
            result: AnkrRawTransactionResult(
                transactions: transactions,
                nextPageToken: nil
            ),
            failure: failure
        )
    }

    private func ankrTokenTransferOutcome(
        address: String,
        chains: [String],
        fromTimestamp: Int64?
    ) async throws -> AnkrTokenTransferLoadOutcome {
        do {
            return AnkrTokenTransferLoadOutcome(
                result: try await tokenTransfersForSnapshot(
                    address: address,
                    chains: chains,
                    fromTimestamp: fromTimestamp
                ),
                failure: nil
            )
        } catch let error as CancellationError {
            throw error
        } catch {
            return try await isolatedTokenTransferOutcome(
                address: address,
                chains: chains,
                fromTimestamp: fromTimestamp,
                aggregateError: error
            )
        }
    }

    private func ankrNativeTransactionOutcome(
        address: String,
        chains: [String],
        fromTimestamp: Int64?
    ) async throws -> AnkrNativeTransactionLoadOutcome {
        do {
            return AnkrNativeTransactionLoadOutcome(
                result: try await nativeTransactionsForSnapshot(
                    address: address,
                    chains: chains,
                    fromTimestamp: fromTimestamp
                ),
                failure: nil
            )
        } catch let error as CancellationError {
            throw error
        } catch {
            return try await isolatedNativeTransactionOutcome(
                address: address,
                chains: chains,
                fromTimestamp: fromTimestamp,
                aggregateError: error
            )
        }
    }

    private func isolatedTokenTransferOutcome(
        address: String,
        chains: [String],
        fromTimestamp: Int64?,
        aggregateError: Error
    ) async throws -> AnkrTokenTransferLoadOutcome {
        let attempts = await withTaskGroup(
            of: AnkrTokenTransferNetworkAttempt.self,
            returning: [AnkrTokenTransferNetworkAttempt].self
        ) { group in
            for networkID in chains {
                group.addTask { [self] in
                    do {
                        return .success(
                            networkID: networkID,
                            result: try await tokenTransfersForSnapshot(
                                address: address,
                                chains: [networkID],
                                fromTimestamp: fromTimestamp
                            )
                        )
                    } catch is CancellationError {
                        return .failure(
                            WalletChainSyncFailure(
                                source: .evm,
                                stage: .historyEnrichment,
                                error: CancellationError(),
                                networkID: networkID
                            )
                        )
                    } catch {
                        return .failure(
                            WalletChainSyncFailure(
                                source: .evm,
                                stage: .historyEnrichment,
                                error: error,
                                networkID: networkID
                            )
                        )
                    }
                }
            }
            var values: [AnkrTokenTransferNetworkAttempt] = []
            for await value in group {
                values.append(value)
            }
            return values
        }
        try Task.checkCancellation()

        var results: [AnkrTokenTransferResult] = []
        var failures: [WalletChainSyncFailure] = []
        for attempt in attempts {
            switch attempt {
            case let .success(_, result): results.append(result)
            case let .failure(failure): failures.append(failure)
            }
        }
        guard !results.isEmpty else {
            return AnkrTokenTransferLoadOutcome(
                result: AnkrTokenTransferResult(
                    transfers: [],
                    nextPageToken: nil
                ),
                failure: WalletChainSyncFailure(
                    source: .evm,
                    stage: .historyEnrichment,
                    error: aggregateError
                )
            )
        }
        return AnkrTokenTransferLoadOutcome(
            result: AnkrTokenTransferResult(
                transfers: results.flatMap(\.transfers),
                nextPageToken: nil
            ),
            failure: failures.sorted {
                ($0.networkID ?? "") < ($1.networkID ?? "")
            }.first
        )
    }

    private func isolatedNativeTransactionOutcome(
        address: String,
        chains: [String],
        fromTimestamp: Int64?,
        aggregateError: Error
    ) async throws -> AnkrNativeTransactionLoadOutcome {
        let attempts = await withTaskGroup(
            of: AnkrNativeTransactionNetworkAttempt.self,
            returning: [AnkrNativeTransactionNetworkAttempt].self
        ) { group in
            for networkID in chains {
                group.addTask { [self] in
                    do {
                        return .success(
                            networkID: networkID,
                            result: try await nativeTransactionsForSnapshot(
                                address: address,
                                chains: [networkID],
                                fromTimestamp: fromTimestamp
                            )
                        )
                    } catch is CancellationError {
                        return .failure(
                            WalletChainSyncFailure(
                                source: .evm,
                                stage: .historyEnrichment,
                                error: CancellationError(),
                                networkID: networkID
                            )
                        )
                    } catch {
                        return .failure(
                            WalletChainSyncFailure(
                                source: .evm,
                                stage: .historyEnrichment,
                                error: error,
                                networkID: networkID
                            )
                        )
                    }
                }
            }
            var values: [AnkrNativeTransactionNetworkAttempt] = []
            for await value in group {
                values.append(value)
            }
            return values
        }
        try Task.checkCancellation()

        var results: [AnkrRawTransactionResult] = []
        var failures: [WalletChainSyncFailure] = []
        for attempt in attempts {
            switch attempt {
            case let .success(_, result): results.append(result)
            case let .failure(failure): failures.append(failure)
            }
        }
        guard !results.isEmpty else {
            return AnkrNativeTransactionLoadOutcome(
                result: AnkrRawTransactionResult(
                    transactions: [],
                    nextPageToken: nil
                ),
                failure: WalletChainSyncFailure(
                    source: .evm,
                    stage: .historyEnrichment,
                    error: aggregateError
                )
            )
        }
        return AnkrNativeTransactionLoadOutcome(
            result: AnkrRawTransactionResult(
                transactions: results.flatMap(\.transactions),
                nextPageToken: nil
            ),
            failure: failures.sorted {
                ($0.networkID ?? "") < ($1.networkID ?? "")
            }.first
        )
    }

    private func tokenTransfersForSnapshot(
        address: String,
        chains: [String],
        fromTimestamp: Int64?
    ) async throws -> AnkrTokenTransferResult {
        do {
            let result: HistoryPaginationResult<AnkrTokenTransfer> =
                try await HistoryPaginator.collect(
                    service: "ANKR",
                    stream: "token_transfers",
                    maximumPages: Self.maximumHistoryPages,
                    maximumItems: Self.maximumRecentHistoryItems
                ) { pageToken in
                    let page = try await self.tokenTransfers(
                        address: address,
                        chains: chains,
                        pageToken: pageToken,
                        fromTimestamp: fromTimestamp
                    )
                    return HistoryPage(
                        items: page.transfers,
                        nextCursor: Self.normalizedPageToken(
                            page.nextPageToken
                        )
                    )
                }
            return AnkrTokenTransferResult(
                transfers: result.items,
                nextPageToken: nil
            )
        } catch {
            throw error
        }
    }

    private func nativeTransactionsForSnapshot(
        address: String,
        chains: [String],
        fromTimestamp: Int64?
    ) async throws -> AnkrRawTransactionResult {
        do {
            let result: HistoryPaginationResult<AnkrRawTransaction> =
                try await HistoryPaginator.collect(
                    service: "ANKR",
                    stream: "native_transactions",
                    maximumPages: Self.maximumHistoryPages,
                    maximumItems: Self.maximumRecentHistoryItems
                ) { pageToken in
                    let page = try await self.nativeTransactions(
                        address: address,
                        chains: chains,
                        pageToken: pageToken,
                        fromTimestamp: fromTimestamp
                    )
                    return HistoryPage(
                        items: page.transactions,
                        nextCursor: Self.normalizedPageToken(
                            page.nextPageToken
                        )
                    )
                }
            return AnkrRawTransactionResult(
                transactions: result.items,
                nextPageToken: nil
            )
        } catch {
            throw error
        }
    }

    func historicalTokenPrices(
        transfers: [AnkrTokenTransfer],
        balanceResult: AnkrBalanceResult,
        cachedPrices: [String: Decimal]
    ) async -> [String: Decimal] {
        let lookupLimit = 25
        let requestLimit = 6
        var seenIdentities = Set<String>()
        var candidates: [AnkrHistoricalTokenPriceCandidate] = []

        for transfer in transfers {
            guard
                let networkID = transfer.blockchain,
                let contract = transfer.contractAddress?.lowercased(),
                Self.isValidAddress(contract)
            else {
                continue
            }
            let identity = Self.assetIdentity(
                chain: networkID,
                contract: contract
            )
            guard seenIdentities.insert(identity).inserted else {
                continue
            }
            if cachedPrices[identity].map({ $0 > 0 }) == true {
                continue
            }
            guard candidates.count < lookupLimit else {
                continue
            }
            candidates.append(
                AnkrHistoricalTokenPriceCandidate(
                    identity: identity,
                    networkID: networkID,
                    contractAddress: contract
                )
            )
        }

        guard !candidates.isEmpty else {
            return cachedPrices
        }

        let prices = await withTaskGroup(
            of: (String, Decimal?).self,
            returning: [String: Decimal].self
        ) { group in
            var iterator = candidates.makeIterator()
            for _ in 0..<min(requestLimit, candidates.count) {
                guard let candidate = iterator.next() else { break }
                group.addTask {
                    let price = await self.tokenPrice(
                        networkID: candidate.networkID,
                        contractAddress: candidate.contractAddress
                    )
                    return (candidate.identity, price)
                }
            }

            var resolved = cachedPrices
            while let (identity, price) = await group.next() {
                if let price, price > 0 {
                    resolved[identity] = price
                }
                if let candidate = iterator.next() {
                    group.addTask {
                        let price = await self.tokenPrice(
                            networkID: candidate.networkID,
                            contractAddress: candidate.contractAddress
                        )
                        return (candidate.identity, price)
                    }
                }
            }
            return resolved
        }
        return prices
    }

    private func tokenTransfers(
        address: String,
        chains: [String],
        pageToken: String?,
        fromTimestamp: Int64?
    ) async throws -> AnkrTokenTransferResult {
        try await transport.call(
            method: "ankr_getTokenTransfers",
            parameters: AnkrHistoryParameters(
                blockchain: chains,
                address: [address],
                descOrder: true,
                pageSize: Self.historyPageSize,
                pageToken: pageToken,
                includeLogs: nil,
                fromTimestamp: fromTimestamp
            )
        )
    }

    private func nativeTransactions(
        address: String,
        chains: [String],
        pageToken: String?,
        fromTimestamp: Int64?
    ) async throws -> AnkrRawTransactionResult {
        try await transport.call(
            method: "ankr_getTransactionsByAddress",
            parameters: AnkrHistoryParameters(
                blockchain: chains,
                address: [address],
                descOrder: true,
                pageSize: Self.historyPageSize,
                pageToken: pageToken,
                includeLogs: false,
                fromTimestamp: fromTimestamp
            )
        )
    }

    func tokenPrice(
        networkID: String,
        contractAddress: String
    ) async -> Decimal? {
        guard Self.isValidAddress(contractAddress),
              let network = WalletBlockchain(ankrIdentifier: networkID) else {
            return nil
        }
        let asset = WalletAsset(
            id: Self.assetIdentity(chain: networkID, contract: contractAddress),
            name: contractAddress, symbol: "", logoSource: .unavailable,
            network: network, balance: 0, fiatValue: 0
        )
        return try? await AssetPriceClient.shared.usdPrice(for: asset).price
    }

    nonisolated static func metadataText(
        _ rawValue: String?,
        maximumLength: Int
    ) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue
            .components(separatedBy: .controlCharacters)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !value.isEmpty,
            value.count <= maximumLength
        else {
            return nil
        }
        return value
    }

    nonisolated static func normalizedPageToken(
        _ rawValue: String?
    ) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return value.isEmpty ? nil : value
    }
}

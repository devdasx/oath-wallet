import Foundation

struct AnkrHistoricalTokenPriceCandidate: Sendable {
    let identity: String
    let networkID: String
    let contractAddress: String
}

struct AnkrWalletLoadOutcome: Sendable {
    let snapshot: WalletHomeSnapshot
    let failures: [WalletChainSyncFailure]
    let historicalTokenPrices: [String: Decimal]
}

struct AnkrTokenTransferLoadOutcome: Sendable {
    let result: AnkrTokenTransferResult
    let failure: WalletChainSyncFailure?
}

struct AnkrNativeTransactionLoadOutcome: Sendable {
    let result: AnkrRawTransactionResult
    let failure: WalletChainSyncFailure?
}

private struct AnkrSelectedAssetHistoryOutcome: Sendable {
    let transfers: [AnkrTokenTransfer]
    let transactions: [AnkrRawTransaction]
    let failure: WalletChainSyncFailure?
}

struct AnkrBalanceLoadOutcome: Sendable {
    let result: AnkrBalanceResult
    let authoritativeNetworkIDs: Set<String>
    let failures: [WalletChainSyncFailure]
}

enum AnkrNetworkBalanceAttempt: Sendable {
    case success(networkID: String, result: AnkrBalanceResult)
    case failure(WalletChainSyncFailure)
}

enum AnkrTokenTransferNetworkAttempt: Sendable {
    case success(networkID: String, result: AnkrTokenTransferResult)
    case failure(WalletChainSyncFailure)
}

enum AnkrNativeTransactionNetworkAttempt: Sendable {
    case success(networkID: String, result: AnkrRawTransactionResult)
    case failure(WalletChainSyncFailure)
}

/// Compatibility facade for ANKR-backed EVM wallet synchronization.
actor AnkrAPIClient {
    /// ANKR Advanced API mainnet aliases supported by the app.
    ///
    /// Keep testnet aliases out of this list: it drives wallet synchronization
    /// and the custom-token network picker.
    static let supportedMainnetChains = [
        "arbitrum",
        "arc",
        "avalanche",
        "base",
        "bsc",
        "eth",
        "gnosis",
        "linea",
        "optimism",
        "polygon",
        "scroll",
        "taiko",
        "telos",
        "xlayer"
    ]

    /// Live capability matrix verified against the production ANKR Advanced
    /// endpoint. Scroll's history methods work, but its account-balance method
    /// returns `No nodes available`, so Scroll balance authority comes from
    /// direct PublicNode JSON-RPC reads instead. Arc is not indexed by ANKR at
    /// all: balances come from PublicNode and history from Blockscout.
    static let advancedBalanceMainnetChains = Set(
        supportedMainnetChains.filter {
            !PublicNodeEVMBalanceClient.authorityNetworkIDs.contains($0)
        }
    )
    static let advancedHistoryMainnetChains = Set(
        supportedMainnetChains.filter {
            !BlockscoutEVMHistoryClient.networkIDs.contains($0)
        }
    )

    let transport: AnkrRPCTransport
    private let publicNodeBalanceClients: [String: PublicNodeEVMBalanceClient]
    let blockscoutHistoryClient: BlockscoutEVMHistoryClient?
    private static let balancePageSize = 1_000
    static let historyPageSize = 1_000
    static let maximumHistoryPages = 100
    /// Bound recent history independently from authoritative balances. Public
    /// EVM addresses can receive an unbounded stream of unsolicited token
    /// transfers; loading every spam event makes refresh latency and memory
    /// attacker-controlled. The database retains previously synchronized
    /// transactions, while each refresh merges the newest bounded window.
    static let maximumRecentHistoryItems = 5_000

    init(configuration: AnkrConfiguration, session: URLSession? = nil) {
        transport = AnkrRPCTransport(
            endpoint: configuration.multichainEndpoint,
            session: session
        )
        publicNodeBalanceClients = Self.publicNodeClients(session: session)
        blockscoutHistoryClient = try? BlockscoutEVMHistoryClient.arc(
            session: session
        )
    }

    init(
        transport: AnkrRPCTransport,
        publicNodeBalanceClient: PublicNodeEVMBalanceClient? = nil,
        blockscoutHistoryClient: BlockscoutEVMHistoryClient? = nil
    ) {
        self.transport = transport
        publicNodeBalanceClients = publicNodeBalanceClient.map {
            [$0.networkID: $0]
        } ?? [:]
        self.blockscoutHistoryClient = blockscoutHistoryClient
    }

    nonisolated static func publicNodeClients(
        session: URLSession?
    ) -> [String: PublicNodeEVMBalanceClient] {
        let clients: [PublicNodeEVMBalanceClient] = [
            .scroll(session: session),
            .arc(session: session)
        ]
        return Dictionary(
            uniqueKeysWithValues: clients.map { ($0.networkID, $0) }
        )
    }

    static func localBuild() throws -> AnkrAPIClient {
        AnkrAPIClient(configuration: try .runtime())
    }

    nonisolated static func isValidAddress(_ value: String) -> Bool {
        value.count == 42
            && value.hasPrefix("0x")
            && value.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    nonisolated static func supportsTokenLookup(
        networkID: String
    ) -> Bool {
        supportedMainnetChains.contains(networkID)
    }

    nonisolated static func usesAdvancedBalance(
        networkID: String
    ) -> Bool {
        advancedBalanceMainnetChains.contains(networkID)
    }

    nonisolated static func usesAdvancedHistory(
        networkID: String
    ) -> Bool {
        advancedHistoryMainnetChains.contains(networkID)
    }

    nonisolated static func usesBlockscoutHistory(
        networkID: String
    ) -> Bool {
        BlockscoutEVMHistoryClient.networkIDs.contains(networkID)
    }

    func lookupToken(
        network: ReceiveNetwork,
        contractAddress: String
    ) async throws -> CustomEVMToken {
        guard Self.supportsTokenLookup(networkID: network.id) else {
            throw AnkrAPIError.unsupportedBlockchain
        }
        let normalizedContract = contractAddress.lowercased()
        guard
            Self.isValidAddress(normalizedContract),
            normalizedContract
                != "0x0000000000000000000000000000000000000000"
        else {
            throw AnkrAPIError.invalidContractAddress
        }

        if let alias = ReceiveNetworkCatalog.nativeAliasContract(
            for: network.id
        ), alias.caseInsensitiveCompare(normalizedContract) == .orderedSame {
            // The interface of the native asset is not a second token.
            throw AnkrAPIError.invalidContractAddress
        }
        guard Self.usesAdvancedHistory(networkID: network.id) else {
            return try await directTokenLookup(
                network: network,
                contractAddress: normalizedContract
            )
        }

        let result: AnkrCurrenciesResult = try await transport.call(
            method: "ankr_getCurrencies",
            parameters: AnkrCurrenciesParameters(
                blockchain: network.id
            )
        )
        try Task.checkCancellation()

        guard let currency = result.currencies.first(where: {
            $0.blockchain == network.id
                && $0.address?.caseInsensitiveCompare(normalizedContract)
                    == .orderedSame
        }) else {
            throw AnkrAPIError.tokenNotFound
        }
        guard
            let name = Self.metadataText(currency.name, maximumLength: 80),
            let symbol = Self.metadataText(
                currency.symbol,
                maximumLength: 24
            ),
            let decimals = currency.decimals,
            (0...255).contains(decimals)
        else {
            throw AnkrAPIError.invalidTokenMetadata
        }

        let providerContract = currency.address ?? normalizedContract
        let logoSource = ReceiveAssetCatalog.variant(
            networkID: network.id,
            contractAddress: providerContract
        )?.logoSource ?? .ankrToken(
            blockchain: network.blockchain,
            contractAddress: providerContract,
            logoURL: currency.thumbnail
        )
        let price = await tokenPrice(
            networkID: network.id,
            contractAddress: normalizedContract
        )

        return CustomEVMToken(
            network: network,
            contractAddress: normalizedContract,
            name: name,
            symbol: symbol,
            decimals: decimals,
            logoSource: logoSource,
            usdPrice: price
        )
    }

    /// `name()`, `symbol()` and `decimals()` read straight from the chain for
    /// mainnets outside ANKR's currency index.
    private func directTokenLookup(
        network: ReceiveNetwork,
        contractAddress: String
    ) async throws -> CustomEVMToken {
        let rpc = try SendEVMRPCClient(networkID: network.id)
        async let nameRead = rpc.tokenStringMetadata(
            contractAddress: contractAddress,
            selector: "0x06fdde03"
        )
        async let symbolRead = rpc.tokenStringMetadata(
            contractAddress: contractAddress,
            selector: "0x95d89b41"
        )
        async let decimalsRead = rpc.tokenDecimals(
            contractAddress: contractAddress
        )
        let (rawName, rawSymbol, decimals) = try await (
            nameRead, symbolRead, decimalsRead
        )
        try Task.checkCancellation()
        guard
            let name = Self.metadataText(
                BlockscoutEVMHistoryClient.decodeABIString(rawName),
                maximumLength: 80
            ),
            let symbol = Self.metadataText(
                BlockscoutEVMHistoryClient.decodeABIString(rawSymbol),
                maximumLength: 24
            ),
            (0...255).contains(decimals)
        else {
            throw AnkrAPIError.invalidTokenMetadata
        }
        let logoSource = ReceiveAssetCatalog.variant(
            networkID: network.id,
            contractAddress: contractAddress
        )?.logoSource ?? .ankrToken(
            blockchain: network.blockchain,
            contractAddress: contractAddress,
            logoURL: nil
        )
        let price = await tokenPrice(
            networkID: network.id,
            contractAddress: contractAddress
        )
        return CustomEVMToken(
            network: network,
            contractAddress: contractAddress,
            name: name,
            symbol: symbol,
            decimals: decimals,
            logoSource: logoSource,
            usdPrice: price
        )
    }

    func loadWallet(address: String) async throws -> WalletHomeSnapshot {
        try await loadWalletWithOutcome(address: address).snapshot
    }

    /// Loads one EVM asset for the asset-details screen through the same
    /// capability matrix as portfolio synchronization. ANKR Advanced API is
    /// authoritative for its verified chains, while Scroll uses the strict
    /// PublicNode inventory batch. User-added contracts outside the verified
    /// catalog retain a dedicated `balanceOf` read because an allowlisted
    /// portfolio response cannot prove their balance. History is chain-scoped
    /// and reduced to the selected native asset or contract here.
    func loadAssetDetails(
        asset: WalletAsset,
        address: String
    ) async throws -> AnkrWalletLoadOutcome {
        guard Self.isValidAddress(address),
              let blockchain = asset.network,
              blockchain.isEVM,
              let network = ReceiveNetworkCatalog.network(for: blockchain),
              Self.supportsTokenLookup(networkID: network.id)
        else {
            throw AnkrAPIError.invalidWalletAddress
        }

        let contract = WalletAssetDetailsSelection.contractAddress(
            for: asset
        )
        if let contract,
           !Self.isValidAddress(contract.lowercased()) {
            throw AnkrAPIError.invalidContractAddress
        }
        let decimals = asset.decimals
            ?? ReceiveToken.nativeAsset(for: network).variants.first?.decimals
            ?? 18
        guard (0...255).contains(decimals) else {
            throw AnkrAPIError.invalidTokenMetadata
        }

        async let balanceValue = selectedAssetAtomicBalance(
            address: address,
            network: network,
            contractAddress: contract,
            decimals: decimals
        )
        async let historyValue = selectedAssetHistoryOutcome(
            address: address,
            networkID: network.id,
            contractAddress: contract
        )
        async let priceValue = AssetPriceClient.shared.usdPrice(for: asset)

        let atomicBalance = try await balanceValue
        let amount = try AnkrTokenAmount(
            rawInteger: atomicBalance,
            normalizedValue: nil,
            decimals: decimals
        )
        let quote = try? await priceValue
        let price = quote?.price
        let fiatValue = price.map { amount.decimalProjection * $0 }
        let history = try await historyValue
        let providerAsset = AnkrBalanceAsset(
            blockchain: network.id,
            tokenName: asset.name,
            tokenSymbol: asset.symbol,
            tokenDecimals: decimals,
            tokenType: contract == nil ? "NATIVE" : "ERC20",
            contractAddress: contract ?? Self.zeroAddress,
            balance: amount.exactMagnitudeText,
            balanceRawInteger: atomicBalance,
            balanceUsd: fiatValue.map {
                NSDecimalNumber(decimal: $0).stringValue
            },
            tokenPrice: price.map {
                NSDecimalNumber(decimal: $0).stringValue
            },
            thumbnail: ""
        )
        let snapshot = try Self.makeSnapshot(
            address: address,
            balanceResult: AnkrBalanceResult(
                totalBalanceUsd: fiatValue.map {
                    NSDecimalNumber(decimal: $0).stringValue
                } ?? "0",
                assets: [providerAsset],
                nextPageToken: nil
            ),
            transfers: history.transfers,
            rawTransactions: history.transactions,
            historicalTokenPrices: price.map {
                [
                    Self.assetIdentity(
                        chain: network.id,
                        contract: contract ?? Self.zeroAddress
                    ): $0
                ]
            } ?? [:],
            authoritativeNetworkIDs: [network.id]
        )
        let selectedTransactions = snapshot.persistenceTransactions.filter {
            WalletAssetDetailsSelection.matches($0, asset: asset)
        }
        return AnkrWalletLoadOutcome(
            snapshot: WalletHomeSnapshot(
                totalBalance: snapshot.totalBalance,
                assets: snapshot.assets,
                transactions: selectedTransactions,
                evmBalanceAuthority: snapshot.evmBalanceAuthority
            ),
            failures: [history.failure].compactMap { $0 },
            historicalTokenPrices: price.map {
                [
                    Self.assetIdentity(
                        chain: network.id,
                        contract: contract ?? Self.zeroAddress
                    ): $0
                ]
            } ?? [:]
        )
    }

    private func selectedAssetAtomicBalance(
        address: String,
        network: ReceiveNetwork,
        contractAddress: String?,
        decimals: Int
    ) async throws -> String {
        if let contractAddress,
           ReceiveAssetCatalog.variant(
               networkID: network.id,
               contractAddress: contractAddress
           )?.isVerified != true {
            return try await directContractAtomicBalance(
                address: address,
                networkID: network.id,
                contractAddress: contractAddress
            )
        }

        let outcome = try await accountBalancesWithFailureIsolation(
            address: address,
            chains: [network.id]
        )
        guard outcome.authoritativeNetworkIDs == Set([network.id]) else {
            throw AnkrAPIError.invalidResponse
        }
        let selected = outcome.result.assets.first { candidate in
            guard candidate.blockchain == network.id else { return false }
            if let contractAddress {
                return candidate.contractAddress.caseInsensitiveCompare(
                    contractAddress
                ) == .orderedSame
            }
            return candidate.tokenType.caseInsensitiveCompare("NATIVE")
                == .orderedSame
        }
        guard let selected else {
            // ANKR's allowlisted inventory cannot prove the value of a
            // verified contract absent from its own whitelist. Read only that
            // contract directly. Scroll's complete catalog batch already
            // queried every selected contract, so omission there proves zero.
            if let contractAddress,
               Self.usesAdvancedBalance(networkID: network.id) {
                return try await directContractAtomicBalance(
                    address: address,
                    networkID: network.id,
                    contractAddress: contractAddress
                )
            }
            return "0"
        }
        guard selected.tokenDecimals == decimals else {
            throw AnkrAPIError.invalidTokenMetadata
        }
        let amount = try AnkrTokenAmount(
            rawInteger: selected.balanceRawInteger,
            normalizedValue: selected.balance,
            decimals: selected.tokenDecimals
        )
        guard let atomic = amount.atomicText else {
            throw AnkrAPIError.invalidResponse
        }
        return atomic
    }

    private func directContractAtomicBalance(
        address: String,
        networkID: String,
        contractAddress: String
    ) async throws -> String {
        let rpc = try SendEVMRPCClient(networkID: networkID)
        let encoded = try await rpc.tokenBalance(
            ownerAddress: address,
            contractAddress: contractAddress
        )
        return try SendAtomicAmount.decimalFromABIUnsignedInteger(encoded)
    }

    /// ANKR exposes separate account-history methods for native transactions
    /// and token transfers. Query only the method relevant to the selected
    /// asset. Token-transfer responses are reduced to the selected contract at
    /// this API boundary before mapping or persistence.
    private func selectedAssetHistoryOutcome(
        address: String,
        networkID: String,
        contractAddress: String?
    ) async throws -> AnkrSelectedAssetHistoryOutcome {
        if let contractAddress {
            let outcome = try await tokenTransferOutcome(
                address: address,
                chains: [networkID],
                fromTimestamp: nil
            )
            return AnkrSelectedAssetHistoryOutcome(
                transfers: outcome.result.transfers.filter { transfer in
                    transfer.blockchain == networkID
                        && transfer.contractAddress?.caseInsensitiveCompare(
                            contractAddress
                        ) == .orderedSame
                },
                transactions: [],
                failure: outcome.failure
            )
        }

        if let alias = ReceiveNetworkCatalog.nativeAliasContract(
            for: networkID
        ) {
            async let interfaceLoad = tokenTransferOutcome(
                address: address,
                chains: [networkID],
                fromTimestamp: nil
            )
            async let nativeLoad = nativeTransactionOutcome(
                address: address,
                chains: [networkID],
                fromTimestamp: nil
            )
            let (interface, native) = try await (interfaceLoad, nativeLoad)
            return AnkrSelectedAssetHistoryOutcome(
                transfers: interface.result.transfers.filter { transfer in
                    transfer.blockchain == networkID
                        && transfer.contractAddress?.caseInsensitiveCompare(
                            alias
                        ) == .orderedSame
                },
                transactions: native.result.transactions.filter {
                    $0.blockchain == networkID
                },
                failure: native.failure ?? interface.failure
            )
        }

        let outcome = try await nativeTransactionOutcome(
            address: address,
            chains: [networkID],
            fromTimestamp: nil
        )
        return AnkrSelectedAssetHistoryOutcome(
            transfers: [],
            transactions: outcome.result.transactions.filter {
                $0.blockchain == networkID
            },
            failure: outcome.failure
        )
    }

    func loadWalletWithOutcome(
        address: String,
        historyFromTimestamp: Int64? = nil,
        cachedHistoricalTokenPrices: [String: Decimal] = [:],
        onBalanceSnapshot:
            (@Sendable (WalletHomeSnapshot) async throws -> Void)? = nil
    ) async throws -> AnkrWalletLoadOutcome {
        try await loadWalletWithOutcome(
            address: address,
            chains: Self.supportedMainnetChains,
            historyFromTimestamp: historyFromTimestamp,
            cachedHistoricalTokenPrices: cachedHistoricalTokenPrices,
            onBalanceSnapshot: onBalanceSnapshot
        )
    }

    /// Reloads the complete balance inventory and recent activity for one EVM
    /// mainnet. Post-broadcast synchronization uses this narrower request so a
    /// transaction on one chain does not trigger unrelated provider traffic.
    func loadNetworkWithOutcome(
        address: String,
        networkID: String,
        historyFromTimestamp: Int64? = nil,
        cachedHistoricalTokenPrices: [String: Decimal] = [:],
        onBalanceSnapshot:
            (@Sendable (WalletHomeSnapshot) async throws -> Void)? = nil
    ) async throws -> AnkrWalletLoadOutcome {
        guard Self.supportsTokenLookup(networkID: networkID) else {
            throw AnkrAPIError.unsupportedBlockchain
        }
        return try await loadWalletWithOutcome(
            address: address,
            chains: [networkID],
            historyFromTimestamp: historyFromTimestamp,
            cachedHistoricalTokenPrices: cachedHistoricalTokenPrices,
            onBalanceSnapshot: onBalanceSnapshot
        )
    }

    private func loadWalletWithOutcome(
        address: String,
        chains: [String],
        historyFromTimestamp: Int64?,
        cachedHistoricalTokenPrices: [String: Decimal],
        onBalanceSnapshot:
            (@Sendable (WalletHomeSnapshot) async throws -> Void)?
    ) async throws -> AnkrWalletLoadOutcome {
        guard Self.isValidAddress(address) else {
            throw AnkrAPIError.invalidWalletAddress
        }
        guard !chains.isEmpty,
              chains.allSatisfy({ Self.supportsTokenLookup(networkID: $0) })
        else {
            throw AnkrAPIError.unsupportedBlockchain
        }

        async let balanceResponse = accountBalancesWithFailureIsolation(
            address: address,
            chains: chains
        )
        async let transferResponse = tokenTransferOutcome(
            address: address,
            chains: chains,
            fromTimestamp: historyFromTimestamp
        )
        async let transactionResponse = nativeTransactionOutcome(
            address: address,
            chains: chains,
            fromTimestamp: historyFromTimestamp
        )

        let balanceLoad = try await balanceResponse
        let balances = balanceLoad.result
        try Task.checkCancellation()
        if let onBalanceSnapshot {
            let balanceSnapshot = try Self.makeSnapshot(
                address: address,
                balanceResult: balances,
                transfers: [],
                rawTransactions: [],
                authoritativeNetworkIDs:
                    balanceLoad.authoritativeNetworkIDs
            )
            try await onBalanceSnapshot(balanceSnapshot)
        }

        let (transfers, transactions) = try await (
            transferResponse,
            transactionResponse
        )

        try Task.checkCancellation()
        let historicalTokenPrices = await historicalTokenPrices(
            transfers: transfers.result.transfers,
            balanceResult: balances,
            cachedPrices: cachedHistoricalTokenPrices
        )
        try Task.checkCancellation()
        let snapshot = try Self.makeSnapshot(
            address: address,
            balanceResult: balances,
            transfers: transfers.result.transfers,
            rawTransactions: transactions.result.transactions,
            historicalTokenPrices: historicalTokenPrices,
            authoritativeNetworkIDs:
                balanceLoad.authoritativeNetworkIDs
        )
        return AnkrWalletLoadOutcome(
            snapshot: snapshot,
            failures: balanceLoad.failures
                + [transfers.failure, transactions.failure]
                    .compactMap { $0 },
            historicalTokenPrices: historicalTokenPrices
        )
    }

    /// Routes each balance method only to a provider proven to support it.
    /// ANKR handles the verified Advanced-API set as one request while Scroll
    /// is read directly from PublicNode. Both independent reads run together;
    /// a provider failure withholds authority only for its affected networks.
    private func accountBalancesWithFailureIsolation(
        address: String,
        chains: [String]
    ) async throws -> AnkrBalanceLoadOutcome {
        guard !publicNodeBalanceClients.isEmpty else {
            // Dependency-injected unit clients may intentionally exercise the
            // raw ANKR aggregation path without production provider routing.
            return try await advancedBalancesWithFailureIsolation(
                address: address,
                chains: chains
            )
        }

        let advancedChains = chains.filter(Self.usesAdvancedBalance)
        let publicNodeChains = chains.filter {
            !Self.usesAdvancedBalance(networkID: $0)
        }
        guard publicNodeChains.allSatisfy({
            publicNodeBalanceClients[$0] != nil
        }) else {
            throw AnkrAPIError.unsupportedBlockchain
        }
        if publicNodeChains.isEmpty {
            return try await advancedBalancesWithFailureIsolation(
                address: address,
                chains: advancedChains
            )
        }

        enum ProviderLoad: Sendable {
            case success(AnkrBalanceLoadOutcome)
            case failure(networkIDs: [String], error: Error)
        }
        let loads = await withTaskGroup(
            of: ProviderLoad.self,
            returning: [ProviderLoad].self
        ) { group in
            if !advancedChains.isEmpty {
                group.addTask { [self] in
                    do {
                        return .success(
                            try await advancedBalancesWithFailureIsolation(
                                address: address,
                                chains: advancedChains
                            )
                        )
                    } catch {
                        return .failure(networkIDs: advancedChains, error: error)
                    }
                }
            }
            for networkID in publicNodeChains {
                guard let client = publicNodeBalanceClients[networkID] else {
                    continue
                }
                group.addTask { [self] in
                    do {
                        return .success(
                            try await publicNodeBalanceOutcome(
                                address: address,
                                networkID: networkID,
                                client: client
                            )
                        )
                    } catch {
                        return .failure(networkIDs: [networkID], error: error)
                    }
                }
            }
            var values: [ProviderLoad] = []
            for await value in group {
                values.append(value)
            }
            return values
        }
        try Task.checkCancellation()

        var successful: [AnkrBalanceLoadOutcome] = []
        var routedFailures: [WalletChainSyncFailure] = []
        var firstError: Error?
        for load in loads {
            switch load {
            case let .success(outcome):
                successful.append(outcome)
            case let .failure(networkIDs, error):
                if error is CancellationError { throw CancellationError() }
                firstError = firstError ?? error
                routedFailures.append(contentsOf: networkIDs.map {
                    WalletChainSyncFailure(
                        source: .evm,
                        stage: .providerRead,
                        error: error,
                        networkID: $0
                    )
                })
            }
        }
        guard !successful.isEmpty else {
            throw firstError ?? AnkrAPIError.invalidResponse
        }
        return Self.mergedBalanceOutcomes(
            successful,
            additionalFailures: routedFailures
        )
    }

    /// When an ANKR multi-chain request fails, retry its supported networks
    /// independently so a healthy chain can still publish authoritative data.
    private func advancedBalancesWithFailureIsolation(
        address: String,
        chains: [String]
    ) async throws -> AnkrBalanceLoadOutcome {
        do {
            return AnkrBalanceLoadOutcome(
                result: try await accountBalancesForSnapshot(
                    address: address,
                    chains: chains
                ),
                authoritativeNetworkIDs: Set(chains),
                failures: []
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let aggregateError = error
            guard chains.count > 1 else { throw aggregateError }
            let attempts = await withTaskGroup(
                of: AnkrNetworkBalanceAttempt.self,
                returning: [AnkrNetworkBalanceAttempt].self
            ) { group in
                for networkID in chains {
                    group.addTask { [self] in
                        do {
                            return .success(
                                networkID: networkID,
                                result: try await accountBalancesForSnapshot(
                                    address: address,
                                    chains: [networkID]
                                )
                            )
                        } catch {
                            return .failure(
                                WalletChainSyncFailure(
                                    source: .evm,
                                    stage: .providerRead,
                                    error: error,
                                    networkID: networkID
                                )
                            )
                        }
                    }
                }
                var values: [AnkrNetworkBalanceAttempt] = []
                for await attempt in group {
                    values.append(attempt)
                }
                return values
            }
            try Task.checkCancellation()

            var successful: [(String, AnkrBalanceResult)] = []
            var failures: [WalletChainSyncFailure] = []
            for attempt in attempts {
                switch attempt {
                case let .success(networkID, result):
                    successful.append((networkID, result))
                case let .failure(failure):
                    failures.append(failure)
                }
            }
            guard !successful.isEmpty else { throw aggregateError }

            return Self.mergedBalanceOutcomes(
                successful.map { networkID, result in
                    AnkrBalanceLoadOutcome(
                        result: result,
                        authoritativeNetworkIDs: [networkID],
                        failures: []
                    )
                },
                additionalFailures: failures
            )
        }
    }

    private func publicNodeBalanceOutcome(
        address: String,
        networkID: String,
        client: PublicNodeEVMBalanceClient
    ) async throws -> AnkrBalanceLoadOutcome {
        AnkrBalanceLoadOutcome(
            result: try await client.accountBalance(address: address),
            authoritativeNetworkIDs: [networkID],
            failures: []
        )
    }

    private nonisolated static func mergedBalanceOutcomes(
        _ outcomes: [AnkrBalanceLoadOutcome],
        additionalFailures: [WalletChainSyncFailure]
    ) -> AnkrBalanceLoadOutcome {
        let totalBalanceUSD = outcomes.reduce(Decimal.zero) {
            partial, outcome in
            partial + (Decimal(
                string: outcome.result.totalBalanceUsd,
                locale: Locale(identifier: "en_US_POSIX")
            ) ?? 0)
        }
        return AnkrBalanceLoadOutcome(
            result: AnkrBalanceResult(
                totalBalanceUsd: NSDecimalNumber(
                    decimal: totalBalanceUSD
                ).stringValue,
                assets: outcomes.flatMap(\.result.assets),
                nextPageToken: nil
            ),
            authoritativeNetworkIDs: outcomes.reduce(into: Set<String>()) {
                $0.formUnion($1.authoritativeNetworkIDs)
            },
            failures: (outcomes.flatMap(\.failures) + additionalFailures)
                .sorted {
                    ($0.networkID ?? "") < ($1.networkID ?? "")
                }
        )
    }

    private func accountBalances(
        address: String,
        chains: [String],
        pageToken: String?
    ) async throws -> AnkrBalanceResult {
        try await transport.call(
            method: "ankr_getAccountBalance",
            parameters: AnkrBalanceParameters(
                blockchain: chains,
                walletAddress: address,
                onlyWhitelisted: true,
                nativeFirst: true,
                pageSize: Self.balancePageSize,
                pageToken: pageToken
            )
        )
    }

    private func accountBalancesForSnapshot(
        address: String,
        chains: [String]
    ) async throws -> AnkrBalanceResult {
        let pages: HistoryPaginationResult<AnkrBalanceResult> =
            try await HistoryPaginator.collect(
                service: "ANKR",
                stream: "account_balances",
                maximumPages: 100
            ) { pageToken in
                let page = try await self.accountBalances(
                    address: address,
                    chains: chains,
                    pageToken: pageToken
                )
                return HistoryPage(
                    items: [page],
                    nextCursor: Self.normalizedPageToken(
                        page.nextPageToken
                    ),
                    reportedItemCount: page.assets.count
                )
            }
        guard let firstPage = pages.items.first else {
            throw AnkrAPIError.invalidResponse
        }
        return AnkrBalanceResult(
            totalBalanceUsd: firstPage.totalBalanceUsd,
            assets: pages.items.flatMap(\.assets),
            nextPageToken: nil
        ).removingUnpricedOpaqueTokenPlaceholders()
    }

}

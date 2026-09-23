import Foundation

enum TronCustomTokenLookupError: Error, Sendable {
    case unsupportedNetwork
    case invalidContractAddress
    case tokenNotFound
    case invalidMetadata
    case unsafeToken

    var diagnosticDescription: String {
        switch self {
        case .unsupportedNetwork: "tron_custom_token_unsupported_network"
        case .invalidContractAddress: "tron_custom_token_invalid_contract"
        case .tokenNotFound: "tron_custom_token_not_found"
        case .invalidMetadata: "tron_custom_token_invalid_metadata"
        case .unsafeToken: "tron_custom_token_blocked_by_safety_policy"
        }
    }
}

actor TronAPIClient {
    private struct HistoryLoad: Sendable {
        let items: [TronHistoryItem]
        let failures: [WalletChainSyncFailure]
    }

    private struct TokenBalanceLoad: Sendable {
        let balances: [TronTokenBalance]
        let queriedIdentities: Set<String>
        let failures: [WalletChainSyncFailure]
    }

    static let shared = TronAPIClient()
    private let transport: TronAPITransport
    private let historyTransport: TronHistoryAPITransport

    init(
        transport: TronAPITransport = .shared,
        historyTransport: TronHistoryAPITransport = .shared
    ) {
        self.transport = transport
        self.historyTransport = historyTransport
    }

    func lookupToken(
        network: ReceiveNetwork,
        contractAddress: String
    ) async throws -> CustomTronToken {
        guard network.id == TronConstants.networkID else {
            throw TronCustomTokenLookupError.unsupportedNetwork
        }
        guard let contractHex = TronValueParser.hexAddress(contractAddress)
        else {
            throw TronCustomTokenLookupError.invalidContractAddress
        }
        guard !TokenSafetyPolicy.isHardDenied(
            networkID: network.id,
            contractAddress: contractAddress
        ) else {
            throw TronCustomTokenLookupError.unsafeToken
        }

        let requests = [
            TronRPCRequest(
                method: "eth_call",
                params: [
                    .object([
                        "to": .string(contractHex),
                        "data": .string("0x06fdde03")
                    ]),
                    .string("latest")
                ],
                id: 1
            ),
            TronRPCRequest(
                method: "eth_call",
                params: [
                    .object([
                        "to": .string(contractHex),
                        "data": .string("0x95d89b41")
                    ]),
                    .string("latest")
                ],
                id: 2
            ),
            TronRPCRequest(
                method: "eth_call",
                params: [
                    .object([
                        "to": .string(contractHex),
                        "data": .string("0x313ce567")
                    ]),
                    .string("latest")
                ],
                id: 3
            )
        ]
        let values = try Self.validatedBatchResponses(
            await transport.rpcBatch(requests),
            expectedIDs: [1, 2, 3]
        )
        guard !values.values.allSatisfy({ $0 == "0x" }) else {
            throw TronCustomTokenLookupError.tokenNotFound
        }
        guard
            let nameValue = values[1],
            let symbolValue = values[2],
            let decimalsValue = values[3],
            let name = TronValueParser.abiText(
                nameValue,
                maximumLength: 80
            ),
            let symbol = TronValueParser.abiText(
                symbolValue,
                maximumLength: 24
            ),
            let decimals = TronValueParser.abiUInt8(decimalsValue)
        else {
            throw TronCustomTokenLookupError.invalidMetadata
        }
        let logoSource = ReceiveAssetCatalog.variant(
            networkID: network.id,
            contractAddress: contractAddress
        )?.logoSource ?? {
            guard TronTokenCatalog.byIdentity[contractAddress] != nil else {
                return .unavailable
            }
            return .catalogToken(
                blockchain: .tron,
                contractAddress: contractAddress,
                logoURL: nil
            )
        }()
        return CustomTronToken(
            network: network,
            contractAddress: contractAddress,
            name: name,
            symbol: symbol,
            decimals: decimals,
            logoSource: logoSource
        )
    }

    func loadSnapshot(
        material: TronAccountMaterial,
        trackedTokens: [TronTrackedToken] = [],
        onNativeBalance:
            (@Sendable (TronWalletSnapshot) async throws -> Void)? = nil
    ) async throws -> TronWalletSnapshot {
        async let native = nativeBalance(hexAddress: material.hexAddress)
        async let nativeHistory = transferHistoryLoad(
            address: material.address
        )
        async let trc20History = tokenHistoryLoad(
            address: material.address
        )
        let trackedMetadata = Self.balanceQueryMetadata(
            trackedTokens: trackedTokens,
            history: []
        )
        let requiredIdentities = Set(
            trackedTokens
                .filter {
                    $0.type == "trc20"
                        && !TokenSafetyPolicy.isHardDenied(
                            networkID: TronConstants.networkID,
                            contractAddress: $0.identity
                        )
                }
                .map(\.identity)
        )
        async let trackedTRC20 = tokenBalances(
            ownerHexAddress: material.hexAddress,
            contracts: Set(trackedMetadata.keys),
            metadata: trackedMetadata,
            requiredIdentities: requiredIdentities
        )

        let trxBalance = try await native
        if let onNativeBalance {
            try await onNativeBalance(
                TronWalletSnapshot(
                    material: material,
                    trxBalance: trxBalance,
                    tokens: [],
                    history: [],
                    queriedTRC20Identities: []
                )
            )
        }
        try Task.checkCancellation()
        var trc20Load = try await trackedTRC20
        if let onNativeBalance {
            try await onNativeBalance(
                TronWalletSnapshot(
                    material: material,
                    trxBalance: trxBalance,
                    tokens: trc20Load.balances,
                    history: [],
                    queriedTRC20Identities: trc20Load.queriedIdentities,
                    providerFailures: trc20Load.failures
                )
            )
        }
        try Task.checkCancellation()

        let history20Load = try await trc20History
        let history20 = history20Load.items
        let discoveredMetadata = Self.balanceQueryMetadata(
            trackedTokens: [],
            history: history20
        ).filter { trackedMetadata[$0.key] == nil }
        if !discoveredMetadata.isEmpty {
            let discoveredLoad = try await tokenBalances(
                ownerHexAddress: material.hexAddress,
                contracts: Set(discoveredMetadata.keys),
                metadata: discoveredMetadata,
                requiredIdentities: []
            )
            trc20Load = Self.mergedTokenBalanceLoads(
                trc20Load,
                discoveredLoad
            )
            if let onNativeBalance {
                try await onNativeBalance(
                    TronWalletSnapshot(
                        material: material,
                        trxBalance: trxBalance,
                        tokens: trc20Load.balances,
                        history: [],
                        queriedTRC20Identities:
                            trc20Load.queriedIdentities,
                        providerFailures: trc20Load.failures
                    )
                )
            }
        }
        let nativeHistoryLoad = try await nativeHistory
        return TronWalletSnapshot(
            material: material,
            trxBalance: trxBalance,
            tokens: trc20Load.balances.sorted {
                $0.symbol.localizedStandardCompare($1.symbol)
                    == .orderedAscending
            },
            history: (nativeHistoryLoad.items + history20)
                .sorted { $0.timestamp > $1.timestamp },
            queriedTRC20Identities: trc20Load.queriedIdentities,
            providerFailures: Self.uniqueFailures(
                trc20Load.failures
                    + nativeHistoryLoad.failures
                    + history20Load.failures
            )
        )
    }

    private func nativeBalance(hexAddress: String) async throws -> Decimal {
        let result = try await transport.rpc(
            method: "eth_getBalance",
            params: [.string(hexAddress), .string("latest")]
        )
        return Decimal(try TronValueParser.hexQuantity(result))
            / TronConstants.sunPerTRX
    }

    nonisolated static func balanceQueryMetadata(
        trackedTokens: [TronTrackedToken],
        history: [TronHistoryItem]
    ) -> [String: TronCatalogFile.Token] {
        var metadata: [String: TronCatalogFile.Token] = [:]
        for token in trackedTokens where
            token.type == "trc20"
                && TronValueParser.hexAddress(token.identity) != nil
                && !TokenSafetyPolicy.isHardDenied(
                    networkID: TronConstants.networkID,
                    contractAddress: token.identity
                )
        {
            metadata[token.identity] = TronCatalogFile.Token(
                id: token.identity,
                type: "trc20",
                name: token.name,
                symbol: token.symbol,
                decimals: token.decimals
            )
        }
        for item in history where
            item.assetIdentity != "native"
                && TronValueParser.hexAddress(item.assetIdentity) != nil
                && !TokenSafetyPolicy.isHardDenied(
                    networkID: TronConstants.networkID,
                    contractAddress: item.assetIdentity
                )
        {
            if let catalogToken =
                TronTokenCatalog.byIdentity[item.assetIdentity]
            {
                guard catalogToken.decimals == item.decimals else {
                    continue
                }
                metadata[item.assetIdentity] = catalogToken
                continue
            }
            guard (0...255).contains(item.decimals),
                  AssetCatalogEntryValidation.isValidRemoteText(
                    item.assetName,
                    maximumLength: 160
                  ),
                  AssetCatalogEntryValidation.isValidRemoteText(
                    item.assetSymbol,
                    maximumLength: 48
                  ),
                  !item.assetSymbol.contains(where: { $0.isWhitespace })
            else {
                continue
            }
            metadata[item.assetIdentity] = TronCatalogFile.Token(
                id: item.assetIdentity,
                type: "trc20",
                name: item.assetName,
                symbol: item.assetSymbol,
                decimals: item.decimals
            )
        }
        return metadata
    }

    private func tokenBalances(
        ownerHexAddress: String,
        contracts: Set<String>,
        metadata: [String: TronCatalogFile.Token],
        requiredIdentities: Set<String>
    ) async throws -> TokenBalanceLoad {
        let owner = String(ownerHexAddress.dropFirst(2))
        let data = "0x70a08231" + String(
            repeating: "0",
            count: max(0, 64 - owner.count)
        ) + owner
        let candidates = contracts.sorted().compactMap { contract -> (
            String,
            TronCatalogFile.Token,
            String
        )? in
            guard let token = metadata[contract] else {
                return nil
            }
            guard let contractHex = TronValueParser.hexAddress(contract) else {
                return nil
            }
            return (contract, token, contractHex)
        }
        var result: [TronTokenBalance] = []
        var queriedIdentities = Set<String>()
        var requiredFailures: [WalletChainSyncFailure] = []
        var firstFailure: WalletChainSyncFailure?
        for chunkStart in stride(
            from: 0,
            to: candidates.count,
            by: 50
        ) {
            let chunk = Array(
                candidates[
                    chunkStart..<min(chunkStart + 50, candidates.count)
                ]
            )
            let requests = chunk.enumerated().map { index, candidate in
                TronRPCRequest(
                    method: "eth_call",
                    params: [
                        .object([
                            "to": .string(candidate.2),
                            "data": .string(data)
                        ]),
                        .string("latest")
                    ],
                    id: index + 1
                )
            }
            let responses: [TronRPCResponse]
            do {
                responses = try await transport.rpcBatch(requests)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let failure = Self.tokenBalanceFailure(error)
                firstFailure = firstFailure ?? failure
                if chunk.contains(where: {
                    requiredIdentities.contains($0.0)
                }) {
                    requiredFailures.append(failure)
                }
                continue
            }
            let byID: [Int: TronRPCResponse]
            do {
                byID = try Self.indexedBatchResponses(
                    responses,
                    expectedIDs: Set(requests.map(\.id))
                )
            } catch {
                let failure = Self.tokenBalanceFailure(error)
                firstFailure = firstFailure ?? failure
                if chunk.contains(where: {
                    requiredIdentities.contains($0.0)
                }) {
                    requiredFailures.append(failure)
                }
                continue
            }
            for (index, candidate) in chunk.enumerated() {
                guard let response = byID[index + 1] else {
                    let failure = Self.tokenBalanceFailure(
                        AnkrAPIError.invalidResponse
                    )
                    firstFailure = firstFailure ?? failure
                    if requiredIdentities.contains(candidate.0) {
                        requiredFailures.append(failure)
                    }
                    continue
                }
                if let error = response.error {
                    let failure = Self.tokenBalanceFailure(error)
                    firstFailure = firstFailure ?? failure
                    if requiredIdentities.contains(candidate.0) {
                        requiredFailures.append(failure)
                    }
                    continue
                }
                guard let raw = response.result else {
                    let failure = Self.tokenBalanceFailure(
                        AnkrAPIError.invalidResponse
                    )
                    firstFailure = firstFailure ?? failure
                    if requiredIdentities.contains(candidate.0) {
                        requiredFailures.append(failure)
                    }
                    continue
                }
                let atomic: TronUInt256
                let amountText: String
                do {
                    atomic = try TronUInt256(hexQuantity: raw)
                    amountText = try atomic.userUnits(
                        decimals: candidate.1.decimals
                    )
                } catch {
                    let failure = Self.tokenBalanceFailure(error)
                    firstFailure = firstFailure ?? failure
                    if requiredIdentities.contains(candidate.0) {
                        requiredFailures.append(failure)
                    }
                    continue
                }
                queriedIdentities.insert(candidate.0)
                guard !atomic.isZero else { continue }
                result.append(
                    TronTokenBalance(
                        identity: candidate.0,
                        type: "trc20",
                        name: candidate.1.name,
                        symbol: candidate.1.symbol,
                        decimals: candidate.1.decimals,
                        amountText: amountText,
                        rawAmount: atomic.decimalText
                    )
                )
            }
        }
        if queriedIdentities.isEmpty,
           !candidates.isEmpty,
           requiredFailures.isEmpty,
           let firstFailure {
            requiredFailures.append(firstFailure)
        }
        return TokenBalanceLoad(
            balances: result,
            queriedIdentities: queriedIdentities,
            failures: Self.uniqueFailures(requiredFailures)
        )
    }

    private static func indexedBatchResponses(
        _ responses: [TronRPCResponse],
        expectedIDs: Set<Int>
    ) throws -> [Int: TronRPCResponse] {
        var indexed: [Int: TronRPCResponse] = [:]
        for response in responses {
            guard
                let id = response.id,
                expectedIDs.contains(id),
                indexed[id] == nil
            else {
                throw AnkrAPIError.invalidResponse
            }
            indexed[id] = response
        }
        guard Set(indexed.keys) == expectedIDs else {
            throw AnkrAPIError.invalidResponse
        }
        return indexed
    }

    static func validatedBatchResponses(
        _ responses: [TronRPCResponse],
        expectedIDs: Set<Int>
    ) throws -> [Int: String] {
        let indexed = try indexedBatchResponses(
            responses,
            expectedIDs: expectedIDs
        )
        var results: [Int: String] = [:]
        for (id, response) in indexed {
            if let error = response.error {
                throw error
            }
            guard let result = response.result else {
                throw AnkrAPIError.invalidResponse
            }
            results[id] = result
        }
        guard Set(results.keys) == expectedIDs else {
            throw AnkrAPIError.invalidResponse
        }
        return results
    }

    private static func tokenBalanceFailure(
        _ error: Error
    ) -> WalletChainSyncFailure {
        WalletChainSyncFailure(
            source: .tron,
            stage: .trackedAssetRead,
            error: error
        )
    }

    private static func mergedTokenBalanceLoads(
        _ lhs: TokenBalanceLoad,
        _ rhs: TokenBalanceLoad
    ) -> TokenBalanceLoad {
        var balancesByIdentity = Dictionary(
            uniqueKeysWithValues: lhs.balances.map { ($0.identity, $0) }
        )
        rhs.balances.forEach { balancesByIdentity[$0.identity] = $0 }
        return TokenBalanceLoad(
            balances: Array(balancesByIdentity.values),
            queriedIdentities: lhs.queriedIdentities
                .union(rhs.queriedIdentities),
            failures: uniqueFailures(lhs.failures + rhs.failures)
        )
    }

    private static func uniqueFailures(
        _ failures: [WalletChainSyncFailure]
    ) -> [WalletChainSyncFailure] {
        var seen = Set<String>()
        return failures.filter {
            seen.insert(
                "\($0.stage.rawValue):\($0.publicCode)"
            ).inserted
        }
    }

    private func tokenHistory(
        address: String
    ) async throws -> [TronHistoryItem] {
        try await historyTransport.tokenHistory(address: address)
    }

    private func tokenHistoryLoad(
        address: String
    ) async throws -> HistoryLoad {
        do {
            return HistoryLoad(
                items: try await tokenHistory(address: address),
                failures: []
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Self.isUnactivatedAccountHistoryResponse(error) {
                return HistoryLoad(items: [], failures: [])
            }
            return HistoryLoad(
                items: [],
                failures: [
                    WalletChainSyncFailure(
                        source: .tron,
                        stage: .historyEnrichment,
                        error: error
                    )
                ]
            )
        }
    }

    private func transferHistory(
        address: String
    ) async throws -> [TronHistoryItem] {
        try await historyTransport.nativeHistory(address: address)
    }

    private func transferHistoryLoad(
        address: String
    ) async throws -> HistoryLoad {
        do {
            return HistoryLoad(
                items: try await transferHistory(address: address),
                failures: []
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Self.isUnactivatedAccountHistoryResponse(error) {
                return HistoryLoad(items: [], failures: [])
            }
            return HistoryLoad(
                items: [],
                failures: [
                    WalletChainSyncFailure(
                        source: .tron,
                        stage: .historyEnrichment,
                        error: error
                    )
                ]
            )
        }
    }

    nonisolated static func isUnactivatedAccountHistoryResponse(
        _ error: Error
    ) -> Bool {
        guard
            let error = error as? AnkrAPIError,
            case let .httpFailure(statusCode, message) = error,
              statusCode == 400
        else {
            return false
        }
        return message?.caseInsensitiveCompare(
            "A valid account address is required."
        ) == .orderedSame
    }

}

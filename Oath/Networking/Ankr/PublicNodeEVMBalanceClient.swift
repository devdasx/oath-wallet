import Foundation

enum PublicNodeEVMBalanceError: Error, Equatable, Sendable {
    case unsupportedNetwork(String)
    case invalidWalletAddress
    case invalidCatalogAsset(String)
    case chainIDMismatch(expected: Int, actual: String)
    case providerRead(
        operation: String,
        contractAddress: String?,
        code: String,
        message: String
    )
    case invalidQuantity(
        operation: String,
        contractAddress: String?
    )

    var diagnosticDescription: String {
        switch self {
        case let .unsupportedNetwork(networkID):
            return "publicnode_unsupported_network=\(networkID)"
        case .invalidWalletAddress:
            return "publicnode_invalid_wallet_address"
        case let .invalidCatalogAsset(identity):
            return "publicnode_invalid_catalog_asset=\(identity)"
        case let .chainIDMismatch(expected, actual):
            return "publicnode_chain_id_mismatch expected=\(expected) actual=\(actual)"
        case let .providerRead(operation, contractAddress, code, message):
            let contract = contractAddress.map { " contract=\($0)" } ?? ""
            return "publicnode_provider_read operation=\(operation)\(contract) code=\(code) message=\(message)"
        case let .invalidQuantity(operation, contractAddress):
            let contract = contractAddress.map { " contract=\($0)" } ?? ""
            return "publicnode_invalid_quantity operation=\(operation)\(contract)"
        }
    }
}

protocol PublicNodeEVMBalanceRPC: Sendable {
    func chainID() async throws -> String
    func nativeBalance(address: String) async throws -> String
    func tokenBalance(
        ownerAddress: String,
        contractAddress: String
    ) async throws -> String
    func accountBalances(
        ownerAddress: String,
        contractAddresses: [String]
    ) async throws -> PublicNodeEVMBalanceBatchResult
}

struct PublicNodeEVMBalanceBatchResult: Sendable {
    let chainID: String
    let nativeBalance: String
    let tokenBalancesByContract: [String: String]
}
extension PublicNodeEVMBalanceRPC {
    func accountBalances(
        ownerAddress _: String,
        contractAddresses _: [String]
    ) async throws -> PublicNodeEVMBalanceBatchResult {
        throw PublicNodeEVMBalanceError.providerRead(
            operation: "batch",
            contractAddress: nil,
            code: "batch_unavailable",
            message: "The RPC implementation does not support batching."
        )
    }
}

/// Loads an authoritative EVM balance inventory from a PublicNode JSON-RPC
/// endpoint when the equivalent ANKR Advanced balance method is unavailable.
///
/// Plain JSON-RPC cannot discover arbitrary ERC-20 contracts. The complete
/// verified app catalog is queried here, while user-added contracts continue
/// through `TrackedEVMTokenBalanceService`. The primary path uses one strict
/// JSON-RPC batch; its bounded concurrent fallback preserves availability.
/// Any unresolved read rejects authority, preventing persisted false zeroes.
struct PublicNodeEVMBalanceClient: Sendable {
    typealias RPCFactory = @Sendable () throws -> any PublicNodeEVMBalanceRPC
    typealias PriceLoader = @Sendable (
        _ assets: [WalletAsset]
    ) async -> [String: Decimal]

    private struct TokenTarget: Sendable {
        let token: ReceiveToken
        let variant: ReceiveTokenVariant
        let contractAddress: String
    }

    private enum BalanceTarget: Sendable {
        case native
        case token(TokenTarget)
    }

    private struct BalanceRead: Sendable {
        let target: BalanceTarget
        let atomicAmount: String
    }

    private struct BalanceInventory: Sendable {
        let chainIDHex: String
        let reads: [BalanceRead]
    }

    private enum BalanceAttempt: Sendable {
        case success(BalanceRead)
        case failure(
            target: BalanceTarget,
            error: PublicNodeEVMBalanceError
        )
    }

    private struct BalancePass: Sendable {
        let reads: [BalanceRead]
        let failures: [(
            target: BalanceTarget,
            error: PublicNodeEVMBalanceError
        )]
    }
    static let scrollNetworkID = "scroll"
    static let scrollEndpoint = URL(
        string: "https://scroll-rpc.publicnode.com"
    )!
    static let arcNetworkID = ArcNetworkConstants.networkID
    static let arcEndpoint = URL(
        string: "https://arc-rpc.publicnode.com"
    )!
    /// Mainnets whose balance authority is a direct PublicNode inventory read
    /// because the ANKR Advanced balance method does not cover them.
    static let authorityNetworkIDs: Set<String> = [
        scrollNetworkID,
        arcNetworkID
    ]
    let networkID: String
    private let expectedChainID: Int
    private let maximumConcurrentReads: Int
    private let chainIDCache: TrackedEVMChainIDCache
    private let rpcFactory: RPCFactory
    private let priceLoader: PriceLoader
    static func scroll(session: URLSession? = nil) -> Self {
        Self(
            networkID: scrollNetworkID,
            expectedChainID: 534_352,
            chainIDCache: .shared,
            rpcFactory: {
                PublicNodeEVMBatchRPCClient(
                    session: session,
                    endpoint: scrollEndpoint
                )
            },
            priceLoader: {
                await AssetPriceClient.usdPrices(
                    for: $0,
                    maximumConcurrentRequests: 6
                )
            }
        )
    }

    static func arc(session: URLSession? = nil) -> Self {
        Self(
            networkID: arcNetworkID,
            expectedChainID: ArcNetworkConstants.chainID,
            chainIDCache: .shared,
            rpcFactory: {
                PublicNodeEVMBatchRPCClient(
                    session: session,
                    endpoint: arcEndpoint
                )
            },
            priceLoader: {
                await AssetPriceClient.usdPrices(
                    for: $0,
                    maximumConcurrentRequests: 6
                )
            }
        )
    }

    init(
        networkID: String,
        expectedChainID: Int,
        maximumConcurrentReads: Int = 8,
        chainIDCache: TrackedEVMChainIDCache = TrackedEVMChainIDCache(),
        rpcFactory: @escaping RPCFactory,
        priceLoader: @escaping PriceLoader
    ) {
        self.networkID = networkID
        self.expectedChainID = expectedChainID
        self.maximumConcurrentReads = max(1, maximumConcurrentReads)
        self.chainIDCache = chainIDCache
        self.rpcFactory = rpcFactory
        self.priceLoader = priceLoader
    }
    func accountBalance(address: String) async throws -> AnkrBalanceResult {
        guard AnkrAPIClient.isValidAddress(address) else {
            throw PublicNodeEVMBalanceError.invalidWalletAddress
        }
        guard let network = ReceiveNetworkCatalog.network(for: networkID),
              network.chainID == expectedChainID,
              network.blockchain.isEVM
        else {
            throw PublicNodeEVMBalanceError.unsupportedNetwork(networkID)
        }

        let client = try rpcFactory()
        let tokenTargets = try catalogTargets()
        let targets: [BalanceTarget] = [.native]
            + tokenTargets.map(BalanceTarget.token)
        let inventory = try await readBalanceInventory(
            targets: targets,
            address: address,
            client: client
        )
        try validateChainID(inventory.chainIDHex)
        let reads = inventory.reads
        try Task.checkCancellation()
        var providerAssets: [AnkrBalanceAsset] = []
        providerAssets.reserveCapacity(reads.count)
        for read in reads {
            let asset = try providerAsset(
                for: read,
                network: network
            )
            if case .native = read.target {
                providerAssets.append(asset)
            } else if read.atomicAmount != "0" {
                providerAssets.append(asset)
            }
        }

        let priceAssets = try providerAssets.compactMap {
            try pricingAsset(for: $0, network: network)
        }
        let prices = await priceLoader(priceAssets)
        let valuedAssets = try providerAssets.map { asset in
            try Self.applyingPrice(
                prices[Self.assetIdentity(for: asset)],
                to: asset
            )
        }
        let total = valuedAssets.reduce(Decimal.zero) { partial, asset in
            partial + (Self.decimal(asset.balanceUsd) ?? 0)
        }
        return AnkrBalanceResult(
            totalBalanceUsd: Self.decimalText(total),
            assets: valuedAssets,
            nextPageToken: nil
        )
    }

    private func catalogTargets() throws -> [TokenTarget] {
        var targetsByContract: [String: TokenTarget] = [:]
        let catalogTokens = ReceiveAssetCatalog.tokens(for: networkID)
        guard !catalogTokens.isEmpty else {
            throw PublicNodeEVMBalanceError.providerRead(
                operation: "catalog",
                contractAddress: nil,
                code: "catalog_unavailable",
                message: "The verified contract catalog is not ready."
            )
        }
        for token in catalogTokens {
            for variant in token.variants where
                variant.networkID == networkID
                    && variant.contractAddress != nil
                    && variant.isVerified
            {
                guard (0...255).contains(variant.decimals),
                      let contract = variant.contractAddress?.lowercased(),
                      AnkrAPIClient.isValidAddress(contract),
                      contract != AnkrAPIClient.zeroAddress
                else {
                    throw PublicNodeEVMBalanceError.invalidCatalogAsset(
                        variant.assetIdentity
                    )
                }
                let candidate = TokenTarget(
                    token: token,
                    variant: variant,
                    contractAddress: contract
                )
                if let current = targetsByContract[contract] {
                    let currentRank = current.variant.networkRank ?? Int.max
                    let candidateRank = variant.networkRank ?? Int.max
                    if candidateRank < currentRank
                        || (
                            candidateRank == currentRank
                                && token.rank < current.token.rank
                        )
                    {
                        targetsByContract[contract] = candidate
                    }
                } else {
                    targetsByContract[contract] = candidate
                }
            }
        }
        guard !targetsByContract.isEmpty else {
            throw PublicNodeEVMBalanceError.providerRead(
                operation: "catalog",
                contractAddress: nil,
                code: "verified_catalog_unavailable",
                message: "The catalog has no verified contracts for this network."
            )
        }
        return targetsByContract.values.sorted {
            let lhsRank = $0.variant.networkRank ?? Int.max
            let rhsRank = $1.variant.networkRank ?? Int.max
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return $0.contractAddress < $1.contractAddress
        }
    }

    private func validateChainID(_ chainIDHex: String) throws {
        let chainID: String
        do {
            chainID = try SendAtomicAmount.decimalFromHexQuantity(
                chainIDHex
            )
        } catch {
            throw PublicNodeEVMBalanceError.invalidQuantity(
                operation: "eth_chainId",
                contractAddress: nil
            )
        }
        guard chainID == String(expectedChainID) else {
            throw PublicNodeEVMBalanceError.chainIDMismatch(
                expected: expectedChainID,
                actual: chainID
            )
        }
    }

    private func readBalanceInventory(
        targets: [BalanceTarget],
        address: String,
        client: any PublicNodeEVMBalanceRPC
    ) async throws -> BalanceInventory {
        let contracts: [String] = targets.compactMap { target in
            guard case let .token(token) = target else { return nil }
            return token.contractAddress
        }
        do {
            let batch = try await accountBalancesWithTransientRetry(
                client: client,
                ownerAddress: address,
                contractAddresses: contracts
            )
            try Task.checkCancellation()
            let reads = try targets.map { target in
                switch target {
                case .native:
                    return BalanceRead(
                        target: target,
                        atomicAmount: try SendAtomicAmount
                            .decimalFromHexQuantity(batch.nativeBalance)
                    )
                case let .token(token):
                    guard let encoded = batch.tokenBalancesByContract[
                        token.contractAddress
                    ] else {
                        throw PublicNodeEVMBalanceError.providerRead(
                            operation: "eth_call",
                            contractAddress: token.contractAddress,
                            code: "missing_batch_result",
                            message: "The batch response omitted a requested contract."
                        )
                    }
                    return BalanceRead(
                        target: target,
                        atomicAmount: try SendAtomicAmount
                            .decimalFromABIUnsignedInteger(encoded)
                    )
                }
            }
            return BalanceInventory(
                chainIDHex: batch.chainID,
                reads: reads
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A malformed, rejected, or unavailable batch must never publish
            // a partial inventory. Retry through the existing per-target path
            // so transient failures can recover without weakening authority.
        }

        let chainIDHex: String
        do {
            chainIDHex = try await chainIDCache.value(
                for: "publicnode:\(networkID)"
            ) {
                try await client.chainID()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.providerError(
                error,
                operation: "eth_chainId",
                contractAddress: nil
            )
        }
        let reads = try await readBalancesIndividually(
            targets: targets,
            address: address,
            client: client
        )
        return BalanceInventory(chainIDHex: chainIDHex, reads: reads)
    }

    private func accountBalancesWithTransientRetry(
        client: any PublicNodeEVMBalanceRPC,
        ownerAddress: String,
        contractAddresses: [String]
    ) async throws -> PublicNodeEVMBalanceBatchResult {
        do {
            return try await client.accountBalances(
                ownerAddress: ownerAddress,
                contractAddresses: contractAddresses
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard Self.isRetryableBatchError(error) else { throw error }
            try Task.checkCancellation()
            return try await client.accountBalances(
                ownerAddress: ownerAddress,
                contractAddresses: contractAddresses
            )
        }
    }

    private static func isRetryableBatchError(_ error: Error) -> Bool {
        guard let error = error as? PublicNodeEVMBalanceError,
              case let .providerRead(_, _, code, _) = error
        else {
            return false
        }
        if [
            "url_-1001", "url_-1003", "url_-1004", "url_-1005",
            "url_-1009", "non_http_response", "invalid_response_count",
            "invalid_response_id", "missing_result"
        ].contains(code) {
            return true
        }
        if code.hasPrefix("http_"),
           let status = Int(code.dropFirst(5)) {
            return status == 408 || status == 425 || status == 429
                || (500...599).contains(status)
        }
        if code.hasPrefix("rpc_"),
           let rpcCode = Int(code.dropFirst(4)) {
            return (-32_099 ... -32_000).contains(rpcCode)
        }
        return false
    }

    private func readBalancesIndividually(
        targets: [BalanceTarget],
        address: String,
        client: any PublicNodeEVMBalanceRPC
    ) async throws -> [BalanceRead] {
        let firstPass = await readBalancePass(
            targets: targets,
            address: address,
            client: client,
            maximumConcurrency: maximumConcurrentReads
        )
        try Task.checkCancellation()
        guard !firstPass.failures.isEmpty else {
            return firstPass.reads
        }

        let retryPass = await readBalancePass(
            targets: firstPass.failures.map(\.target),
            address: address,
            client: client,
            maximumConcurrency: min(2, maximumConcurrentReads)
        )
        try Task.checkCancellation()
        guard !retryPass.failures.isEmpty else {
            return firstPass.reads + retryPass.reads
        }

        let finalPass = await readBalancePass(
            targets: retryPass.failures.map(\.target),
            address: address,
            client: client,
            maximumConcurrency: 1
        )
        try Task.checkCancellation()
        guard let unresolved = finalPass.failures.first else {
            return firstPass.reads + retryPass.reads + finalPass.reads
        }
        throw unresolved.error
    }

    private func readBalancePass(
        targets: [BalanceTarget],
        address: String,
        client: any PublicNodeEVMBalanceRPC,
        maximumConcurrency: Int
    ) async -> BalancePass {
        await withTaskGroup(
            of: BalanceAttempt.self,
            returning: BalancePass.self
        ) { group in
            var iterator = targets.makeIterator()
            for _ in 0..<min(maximumConcurrency, targets.count) {
                guard let target = iterator.next() else { break }
                group.addTask {
                    await Self.balanceAttempt(
                        target: target,
                        address: address,
                        client: client
                    )
                }
            }

            var values: [BalanceRead] = []
            var failures: [(
                target: BalanceTarget,
                error: PublicNodeEVMBalanceError
            )] = []
            values.reserveCapacity(targets.count)
            while let attempt = await group.next() {
                switch attempt {
                case let .success(value):
                    values.append(value)
                case let .failure(target, error):
                    failures.append((target, error))
                }
                if let target = iterator.next() {
                    group.addTask {
                        await Self.balanceAttempt(
                            target: target,
                            address: address,
                            client: client
                        )
                    }
                }
            }
            return BalancePass(reads: values, failures: failures)
        }
    }

    private static func balanceAttempt(
        target: BalanceTarget,
        address: String,
        client: any PublicNodeEVMBalanceRPC
    ) async -> BalanceAttempt {
        do {
            return .success(
                try await readBalance(
                    target: target,
                    address: address,
                    client: client
                )
            )
        } catch let error as PublicNodeEVMBalanceError {
            return .failure(target: target, error: error)
        } catch is CancellationError {
            return .failure(
                target: target,
                error: .providerRead(
                    operation: "cancelled",
                    contractAddress: nil,
                    code: "cancelled",
                    message: "cancelled"
                )
            )
        } catch {
            return .failure(
                target: target,
                error: providerError(
                    error,
                    operation: "unknown",
                    contractAddress: nil
                )
            )
        }
    }

    private static func readBalance(
        target: BalanceTarget,
        address: String,
        client: any PublicNodeEVMBalanceRPC
    ) async throws -> BalanceRead {
        let operation: String
        let contractAddress: String?
        let encoded: String
        do {
            switch target {
            case .native:
                operation = "eth_getBalance"
                contractAddress = nil
                encoded = try await client.nativeBalance(address: address)
            case let .token(token):
                operation = "eth_call"
                contractAddress = token.contractAddress
                encoded = try await client.tokenBalance(
                    ownerAddress: address,
                    contractAddress: token.contractAddress
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            switch target {
            case .native:
                throw providerError(
                    error,
                    operation: "eth_getBalance",
                    contractAddress: nil
                )
            case let .token(token):
                throw providerError(
                    error,
                    operation: "eth_call",
                    contractAddress: token.contractAddress
                )
            }
        }

        let atomicAmount: String
        do {
            switch target {
            case .native:
                atomicAmount = try SendAtomicAmount
                    .decimalFromHexQuantity(encoded)
            case .token:
                atomicAmount = try SendAtomicAmount
                    .decimalFromABIUnsignedInteger(encoded)
            }
        } catch {
            throw PublicNodeEVMBalanceError.invalidQuantity(
                operation: operation,
                contractAddress: contractAddress
            )
        }
        return BalanceRead(
            target: target,
            atomicAmount: atomicAmount
        )
    }

    private func providerAsset(
        for read: BalanceRead,
        network: ReceiveNetwork
    ) throws -> AnkrBalanceAsset {
        let name: String
        let symbol: String
        let decimals: Int
        let tokenType: String
        let contractAddress: String
        let thumbnail: String
        switch read.target {
        case .native:
            let native = ReceiveToken.nativeAsset(for: network)
            guard let variant = native.variants.first else {
                throw PublicNodeEVMBalanceError.invalidCatalogAsset(
                    "\(networkID):native"
                )
            }
            name = native.name
            symbol = native.symbol
            decimals = variant.decimals
            tokenType = "NATIVE"
            contractAddress = AnkrAPIClient.zeroAddress
            thumbnail = ""
        case let .token(target):
            name = target.token.name
            symbol = target.token.symbol
            decimals = target.variant.decimals
            tokenType = "ERC20"
            contractAddress = target.contractAddress
            thumbnail = target.variant.logoURL ?? ""
        }
        let amount = try AnkrTokenAmount(
            rawInteger: read.atomicAmount,
            normalizedValue: nil,
            decimals: decimals
        )
        return AnkrBalanceAsset(
            blockchain: networkID,
            tokenName: name,
            tokenSymbol: symbol,
            tokenDecimals: decimals,
            tokenType: tokenType,
            contractAddress: contractAddress,
            balance: amount.exactMagnitudeText,
            balanceRawInteger: amount.atomicText,
            balanceUsd: nil,
            tokenPrice: nil,
            thumbnail: thumbnail
        )
    }

    private func pricingAsset(
        for asset: AnkrBalanceAsset,
        network: ReceiveNetwork
    ) throws -> WalletAsset? {
        let amount = try AnkrTokenAmount(
            rawInteger: asset.balanceRawInteger,
            normalizedValue: asset.balance,
            decimals: asset.tokenDecimals
        )
        guard amount.exactMagnitudeText != "0" else { return nil }
        let isNative = asset.tokenType == "NATIVE"
        return WalletAsset(
            id: Self.assetIdentity(for: asset),
            name: asset.tokenName,
            symbol: asset.tokenSymbol,
            logoSource: isNative
                ? .nativeCoin(blockchain: network.blockchain)
                : ReceiveAssetCatalog.variant(
                    networkID: networkID,
                    contractAddress: asset.contractAddress
                )?.logoSource ?? .unavailable,
            network: network.blockchain,
            balance: amount.decimalProjection,
            fiatValue: 0,
            balanceText: amount.exactMagnitudeText,
            balanceAtomic: amount.atomicText,
            decimals: asset.tokenDecimals,
            isVerified: true
        )
    }

    private static func applyingPrice(
        _ price: Decimal?,
        to asset: AnkrBalanceAsset
    ) throws -> AnkrBalanceAsset {
        guard let price else { return asset }
        let amount = try AnkrTokenAmount(
            rawInteger: asset.balanceRawInteger,
            normalizedValue: asset.balance,
            decimals: asset.tokenDecimals
        )
        return AnkrBalanceAsset(
            blockchain: asset.blockchain,
            tokenName: asset.tokenName,
            tokenSymbol: asset.tokenSymbol,
            tokenDecimals: asset.tokenDecimals,
            tokenType: asset.tokenType,
            contractAddress: asset.contractAddress,
            balance: asset.balance,
            balanceRawInteger: asset.balanceRawInteger,
            balanceUsd: decimalText(amount.decimalProjection * price),
            tokenPrice: decimalText(price),
            thumbnail: asset.thumbnail
        )
    }

    private static func providerError(
        _ error: Error,
        operation: String,
        contractAddress: String?
    ) -> PublicNodeEVMBalanceError {
        if let error = error as? SendTransactionSubmissionError,
           case let .provider(_, code, message) = error {
            return .providerRead(
                operation: operation,
                contractAddress: contractAddress,
                code: sanitized(code),
                message: sanitized(message)
            )
        }
        if let error = error as? URLError {
            return .providerRead(
                operation: operation,
                contractAddress: contractAddress,
                code: "url_\(error.code.rawValue)",
                message: sanitized(error.localizedDescription)
            )
        }
        return .providerRead(
            operation: operation,
            contractAddress: contractAddress,
            code: SendTransactionSubmissionError.sanitizedErrorType(error),
            message: sanitized(String(describing: error))
        )
    }

    private static func assetIdentity(for asset: AnkrBalanceAsset) -> String {
        AnkrAPIClient.assetIdentity(
            chain: asset.blockchain,
            contract: asset.contractAddress
        )
    }

    private static func decimal(_ value: String?) -> Decimal? {
        guard let value else { return nil }
        return Decimal(
            string: value,
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func decimalText(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private static func sanitized(_ value: String) -> String {
        let clean = value
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((clean.isEmpty ? "empty_provider_message" : clean).prefix(500))
    }
}

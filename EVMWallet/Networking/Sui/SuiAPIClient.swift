import Foundation

actor SuiAPIClient {
    static let shared = SuiAPIClient()

    private let transport: SuiGraphQLTransport
    private let transactionExecutor: SuiTransactionExecutor?

    init(transport: SuiGraphQLTransport? = nil) {
        self.transactionExecutor = transport == nil ? SuiTransactionExecutor() : nil
        self.transport = transport
            ?? SuiGraphQLTransport()
    }

    func loadSnapshot(
        material: SuiAccountMaterial,
        onBalances:
            (@Sendable (SuiWalletSnapshot) async throws -> Void)? = nil
    ) async throws -> SuiWalletSnapshot {
        guard let owner = SuiCoinType.validatedAccountAddress(
            material.address
        ) else {
            throw SuiProviderError.invalidAddress
        }
        async let loadedBalances = balances(address: owner)
        async let loadedHistory = history(address: owner)
        let balanceNodes = try await loadedBalances
        let loadedNativeBalance = try nativeBalance(from: balanceNodes)
        if let onBalances {
            try await onBalances(
                SuiWalletSnapshot(
                    material: material,
                    balances: [loadedNativeBalance],
                    history: [],
                    balancesAreAuthoritative: false,
                    historyIsAuthoritative: false,
                    providerFailureCodes: [],
                    successfulBalanceAssetIDs: [
                        SuiConstants.nativeAssetID
                    ]
                )
            )
        }
        try Task.checkCancellation()
        let balanceTypes = Set(
            balanceNodes.compactMap {
                SuiCoinType.canonical($0.coinType.repr)
            }
        )
        let balanceMetadataLoad = await metadataByCoinType(balanceTypes)
        let missingBalanceMetadata = balanceTypes.intersection(
            balanceMetadataLoad.failedCoinTypes
        )
        let balanceMapping = try mappedBalances(
            balanceNodes,
            metadata: balanceMetadataLoad.metadata
        )
        let balancesAuthoritative = missingBalanceMetadata.isEmpty
            && balanceMapping.failureCodes.isEmpty
        let balances = balanceMapping.balances
        let successfulBalanceAssetIDs = Set(
            balances.compactMap(\.assetID)
        )
        var providerFailures = balanceMapping.failureCodes
        if !missingBalanceMetadata.isEmpty {
            providerFailures.append("sui_balance_metadata_incomplete")
        }
        if let onBalances {
            try await onBalances(
                SuiWalletSnapshot(
                    material: material,
                    balances: balances,
                    history: [],
                    balancesAreAuthoritative: balancesAuthoritative,
                    historyIsAuthoritative: false,
                    providerFailureCodes: providerFailures,
                    successfulBalanceAssetIDs:
                        successfulBalanceAssetIDs
                )
            )
        }
        try Task.checkCancellation()

        let historyLoad: SuiHistoryLoad
        var historyAuthoritative = true
        do {
            historyLoad = try await loadedHistory
            if !historyLoad.isComplete {
                historyAuthoritative = false
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            historyLoad = SuiHistoryLoad(
                transactions: [],
                isComplete: false
            )
            historyAuthoritative = false
            providerFailures.append(Self.failureCode(error))
        }

        let historyTypes = Set(
            historyLoad.transactions.flatMap {
                $0.balanceChanges.compactMap {
                    SuiCoinType.canonical($0.coinType)
                }
            }
        )
        let historyMetadataLoad = await metadataByCoinType(
            historyTypes.subtracting(balanceTypes)
        )
        var metadata = balanceMetadataLoad.metadata
        metadata.merge(
            historyMetadataLoad.metadata,
            uniquingKeysWith: { current, _ in current }
        )
        let failedCoinTypes =
            balanceMetadataLoad.failedCoinTypes.union(
                historyMetadataLoad.failedCoinTypes
            )
        let missingHistoryMetadata = historyTypes.intersection(
            failedCoinTypes
        )
        if !missingHistoryMetadata.isEmpty {
            historyAuthoritative = false
            providerFailures.append("sui_history_metadata_incomplete")
        }
        return SuiWalletSnapshot(
            material: material,
            balances: balances,
            history: try mapHistory(
                historyLoad.transactions,
                owner: owner,
                metadata: metadata
            ),
            balancesAreAuthoritative: balancesAuthoritative,
            historyIsAuthoritative: historyAuthoritative,
            providerFailureCodes: Array(Set(providerFailures)).sorted(),
            successfulBalanceAssetIDs: successfulBalanceAssetIDs
        )
    }

    private func nativeBalance(
        from nodes: [SuiBalancesResponse.Node]
    ) throws -> SuiAssetBalance {
        let node = nodes.first {
            SuiCoinType.canonical($0.coinType.repr)
                == SuiConstants.nativeCoinType
        }
        let atomic = try node.map {
            guard let value = ExactDecimalText.canonicalUnsignedInteger(
                $0.totalBalance
            ) else {
                throw SuiProviderError.invalidResponse(
                    "native_balance"
                )
            }
            return value
        } ?? "0"
        return SuiAssetBalance(
            metadata: SuiTokenCatalog.native,
            amountText: try Self.userUnits(
                atomic: atomic,
                decimals: SuiConstants.decimals
            ),
            atomicAmount: atomic
        )
    }

    private func mappedBalances(
        _ nodes: [SuiBalancesResponse.Node],
        metadata: [String: SuiTokenMetadata]
    ) throws -> SuiBalanceMapping {
        var balances: [SuiAssetBalance] = []
        var seenCoinTypes = Set<String>()
        var failureCodes = Set<String>()
        for node in nodes {
            guard let coinType = SuiCoinType.canonical(
                node.coinType.repr
            ), let atomic = ExactDecimalText
                .canonicalUnsignedInteger(node.totalBalance)
            else {
                failureCodes.insert("sui_balance_item_invalid")
                continue
            }
            guard seenCoinTypes.insert(coinType).inserted else {
                failureCodes.insert("sui_balance_item_duplicate")
                continue
            }
            guard let token = SuiTokenCatalog.metadata(
                coinType: coinType,
                provider: metadata[coinType]
            ) else {
                continue
            }
            balances.append(
                SuiAssetBalance(
                    metadata: token,
                    amountText: try Self.userUnits(
                        atomic: atomic,
                        decimals: token.decimals
                    ),
                    atomicAmount: atomic
                )
            )
        }
        if !balances.contains(where: {
            $0.metadata.coinType == SuiConstants.nativeCoinType
        }) {
            balances.append(
                SuiAssetBalance(
                    metadata: SuiTokenCatalog.native,
                    amountText: "0",
                    atomicAmount: "0"
                )
            )
        }
        return SuiBalanceMapping(
            balances: balances.sorted {
                $0.metadata.rank < $1.metadata.rank
            },
            failureCodes: failureCodes.sorted()
        )
    }

    func coinObjects(
        address: String,
        coinType: String
    ) async throws -> [SuiCoinObject] {
        guard let owner = SuiCoinType.validatedAccountAddress(address),
              let canonicalType = SuiCoinType.canonical(coinType)
        else {
            throw SuiProviderError.invalidAddress
        }
        let objectType = "0x2::coin::Coin<\(canonicalType)>"
        var cursor: String?
        var seenCursors = Set<String>()
        var seen = Set<String>()
        var result: [SuiCoinObject] = []
        for _ in 0..<SuiConstants.maximumObjectPages {
            let page: SuiCoinObjectsResponse = try await transport.request(
                query: Self.coinObjectsQuery,
                variables: [
                    "address": .string(owner),
                    "type": .string(objectType),
                    "first": .integer(SuiConstants.objectPageSize),
                    "after": cursor.map(SuiGraphQLValue.string) ?? .null
                ]
            )
            guard let connection = page.address?.objects else {
                throw SuiProviderError.invalidResponse("objects_address")
            }
            for node in connection.nodes
            where seen.insert(node.address).inserted {
                guard let balance = node.contents?.json?.balance,
                      let atomic = UInt64(balance)
                else {
                    throw SuiProviderError.invalidResponse("object_balance")
                }
                result.append(
                    SuiCoinObject(
                        objectID: node.address,
                        version: node.version,
                        digest: node.digest,
                        atomicBalance: atomic
                    )
                )
            }
            guard connection.pageInfo.hasNextPage else {
                return result
            }
            guard let next = connection.pageInfo.endCursor,
                  seenCursors.insert(next).inserted
            else {
                throw SuiProviderError.invalidResponse("objects_cursor")
            }
            cursor = next
        }
        throw SuiProviderError.invalidResponse("objects_page_limit")
    }

    func referenceGasPrice() async throws -> UInt64 {
        let response: SuiEpochResponse = try await transport.request(
            query: Self.epochQuery,
            variables: [:]
        )
        guard let value = response.epoch?.referenceGasPrice,
              let price = UInt64(value), price > 0
        else {
            throw SuiProviderError.invalidResponse("gas_price")
        }
        return price
    }

    func transactionStatus(
        digest: String
    ) async throws -> SendTransactionNetworkStatus {
        guard SendTransactionStatusValidation.isBase58Hash(
            digest,
            byteCount: 32
        ) else {
            throw SendTransactionStatusProviderError
                .invalidTransactionHash(networkID: SuiConstants.networkID)
        }
        let response: SuiTransactionStatusResponse = try await transport
            .request(
                query: Self.transactionStatusQuery,
                variables: ["digest": .string(digest)]
            )
        guard let effects = response.transactionEffects else {
            return .notFound
        }
        switch effects.status.uppercased() {
        case "SUCCESS":
            return .confirmed
        case "FAILURE":
            return .failed
        default:
            throw SuiProviderError.invalidResponse(
                "transaction_status"
            )
        }
    }

    func execute(
        transactionDataBCS: String,
        signature: String
    ) async throws -> String {
        if let transactionExecutor {
            return try await transactionExecutor.execute(transaction: transactionDataBCS, signature: signature)
        }
        let response: SuiExecuteResponse = try await transport.submit(
            query: Self.executeQuery,
            variables: [
                "transaction": .string(transactionDataBCS),
                "signature": .string(signature)
            ]
        )
        guard let result = response.executeTransaction else {
            throw SuiProviderError.invalidResponse("execute_result")
        }
        guard let effects = result.effects,
              let digest = effects.digest,
              !digest.isEmpty
        else {
            throw SuiProviderError.invalidResponse("execute_effects")
        }
        guard effects.status == "SUCCESS" else {
            throw SuiProviderError.executionFailed(
                code: Self.publicCode(
                    effects.executionError?.message
                        ?? "execution_failed"
                ),
                digest: digest
            )
        }
        return digest
    }

    private func balances(
        address: String
    ) async throws -> [SuiBalancesResponse.Node] {
        var cursor: String?
        var seenCursors = Set<String>()
        var result: [SuiBalancesResponse.Node] = []
        for _ in 0..<SuiConstants.maximumBalancePages {
            let response: SuiBalancesResponse = try await transport.request(
                query: Self.balancesQuery,
                variables: [
                    "address": .string(address),
                    "first": .integer(SuiConstants.balancePageSize),
                    "after": cursor.map(SuiGraphQLValue.string) ?? .null
                ]
            )
            guard let connection = response.address?.balances else {
                throw SuiProviderError.invalidResponse("balances_address")
            }
            result.append(contentsOf: connection.nodes)
            guard connection.pageInfo.hasNextPage else {
                return result
            }
            guard let next = connection.pageInfo.endCursor,
                  seenCursors.insert(next).inserted
            else {
                throw SuiProviderError.invalidResponse("balances_cursor")
            }
            cursor = next
        }
        throw SuiProviderError.invalidResponse("balances_page_limit")
    }

    private func history(
        address: String
    ) async throws -> SuiHistoryLoad {
        var cursor: String?
        var seenCursors = Set<String>()
        var result: [SuiHistoryTransaction] = []
        var isComplete = true
        for pageIndex in 0..<SuiConstants.maximumHistoryPages {
            let response: SuiTransactionsResponse = try await transport.request(
                query: Self.historyQuery,
                variables: [
                    "address": .string(address),
                    "last": .integer(SuiConstants.historyPageSize),
                    "changeFirst": .integer(
                        SuiConstants.balanceChangePageSize
                    ),
                    "before": cursor.map(SuiGraphQLValue.string) ?? .null
                ]
            )
            guard let connection = response.address?.transactions else {
                throw SuiProviderError.invalidResponse("history_address")
            }
            for node in connection.nodes {
                guard let effects = node.effects else { continue }
                let changes = try await completeBalanceChanges(
                    digest: node.digest,
                    initial: effects.balanceChanges
                )
                let gasSummary = effects.gasEffects?.gasSummary.map {
                    SuiGasCostSummary(
                        computationCost: $0.computationCost,
                        storageCost: $0.storageCost,
                        storageRebate: $0.storageRebate,
                        nonRefundableStorageFee:
                            $0.nonRefundableStorageFee
                    )
                }
                result.append(
                    SuiHistoryTransaction(
                        digest: node.digest,
                        sender: node.sender?.address,
                        status: effects.status,
                        timestamp: effects.timestamp,
                        balanceChanges: changes.map {
                            SuiHistoryBalanceChange(
                                owner: $0.owner?.address,
                                coinType: $0.coinType.repr,
                                amount: $0.amount
                            )
                        },
                        gasSummary: gasSummary
                    )
                )
            }
            guard connection.pageInfo.hasPreviousPage else {
                break
            }
            guard let next = connection.pageInfo.startCursor,
                  seenCursors.insert(next).inserted
            else {
                throw SuiProviderError.invalidResponse("history_cursor")
            }
            if pageIndex == SuiConstants.maximumHistoryPages - 1 {
                isComplete = false
                break
            }
            cursor = next
        }
        return SuiHistoryLoad(
            transactions: result,
            isComplete: isComplete
        )
    }

    private func completeBalanceChanges(
        digest: String,
        initial: SuiTransactionsResponse.BalanceChanges
    ) async throws -> [SuiTransactionsResponse.BalanceChange] {
        var result = initial.nodes
        let firstCursor: String?
        if initial.pageInfo.hasNextPage {
            guard let value = initial.pageInfo.endCursor else {
                throw SuiProviderError.invalidResponse(
                    "history_balance_cursor"
                )
            }
            firstCursor = value
        } else {
            firstCursor = nil
        }
        var cursor = firstCursor
        var seenCursors = Set<String>()
        var pageCount = 0
        while let after = cursor {
            guard pageCount < SuiConstants.maximumBalanceChangePages,
                  seenCursors.insert(after).inserted
            else {
                throw SuiProviderError.invalidResponse(
                    "history_balance_page_limit"
                )
            }
            pageCount += 1
            let response: SuiBalanceChangesResponse = try await
                transport.request(
                    query: Self.balanceChangesQuery,
                    variables: [
                        "digest": .string(digest),
                        "first": .integer(
                            SuiConstants.balanceChangePageSize
                        ),
                        "after": .string(after)
                    ]
                )
            guard let connection = response.transactionEffects?
                .balanceChanges
            else {
                throw SuiProviderError.invalidResponse(
                    "history_balance_changes"
                )
            }
            result.append(contentsOf: connection.nodes)
            if connection.pageInfo.hasNextPage {
                guard let next = connection.pageInfo.endCursor else {
                    throw SuiProviderError.invalidResponse(
                        "history_balance_cursor"
                    )
                }
                cursor = next
            } else {
                cursor = nil
            }
        }
        return result
    }

    private func metadataByCoinType(
        _ rawTypes: Set<String>
    ) async -> SuiMetadataLoad {
        let coinTypes = Array(
            Set(rawTypes.compactMap(SuiCoinType.canonical))
        ).sorted()
        var metadata: [String: SuiTokenMetadata] = [:]
        var pending: [String] = []
        for coinType in coinTypes {
            if let catalog = SuiTokenCatalog.byCoinType[coinType] {
                metadata[coinType] = catalog
            } else {
                pending.append(coinType)
            }
        }

        var failed = Set<String>()
        let limit = SuiConstants.metadataConcurrencyLimit
        for start in stride(from: 0, to: pending.count, by: limit) {
            let end = min(start + limit, pending.count)
            let batch = Array(pending[start..<end])
            let loaded = await withTaskGroup(
                of: (String, SuiTokenMetadata?).self,
                returning: [(String, SuiTokenMetadata?)].self
            ) { group in
                for coinType in batch {
                    group.addTask {
                        do {
                            let value: SuiCoinMetadataResponse =
                                try await self.transport.request(
                                    query: Self.metadataQuery,
                                    variables: [
                                        "type": .string(coinType)
                                    ]
                                )
                            guard let item = value.coinMetadata,
                                  (0...255).contains(item.decimals),
                                  let name = Self.sanitizedMetadataText(
                                      item.name,
                                      maximumLength: 128
                                  ),
                                  let symbol = Self.sanitizedMetadataText(
                                      item.symbol,
                                      maximumLength: 32
                                  )
                            else {
                                return (coinType, nil)
                            }
                            let iconURL: URL? = item.iconUrl.flatMap {
                                value -> URL? in
                                guard let url = URL(string: value),
                                      url.scheme == "https"
                                else {
                                    return nil
                                }
                                return url
                            }
                            return (
                                coinType,
                                SuiTokenMetadata(
                                    coinType: coinType,
                                    name: name,
                                    symbol: symbol,
                                    decimals: item.decimals,
                                    iconURL: iconURL,
                                    isVerified: false,
                                    rank: 10_000
                                )
                            )
                        } catch {
                            return (coinType, nil)
                        }
                    }
                }
                var values: [(String, SuiTokenMetadata?)] = []
                for await value in group {
                    values.append(value)
                }
                return values
            }
            for (coinType, item) in loaded {
                if let item {
                    metadata[coinType] = item
                } else {
                    failed.insert(coinType)
                }
            }
        }
        return SuiMetadataLoad(
            metadata: metadata,
            failedCoinTypes: failed
        )
    }

    private func mapHistory(
        _ nodes: [SuiHistoryTransaction],
        owner: String,
        metadata: [String: SuiTokenMetadata]
    ) throws -> [SuiHistoryItem] {
        var result: [SuiHistoryItem] = []
        for node in nodes {
            guard let timestamp = Self.historyTimestamp(node.timestamp)
            else {
                continue
            }
            let sender = node.sender.flatMap(
                SuiCoinType.canonicalAccountAddress
            )
            let ownerPaysGas = sender == owner
            let networkFeeAtomic = ownerPaysGas
                ? node.gasSummary?.netFee : nil
            let networkFeeText = try networkFeeAtomic.map {
                try Self.userUnits(
                    atomic: String($0),
                    decimals: SuiConstants.decimals
                )
            }
            for (index, change) in node.balanceChanges.enumerated() {
                guard let changeOwner = change.owner,
                      SuiCoinType.canonicalAccountAddress(changeOwner) == owner,
                      let coinType = SuiCoinType.canonical(
                        change.coinType
                      ), let token = SuiTokenCatalog.metadata(
                        coinType: coinType,
                        provider: metadata[coinType]
                      ), let magnitude = ExactDecimalText
                        .canonicalMagnitude(change.amount)
                else {
                    continue
                }
                let outgoing = change.amount.hasPrefix("-")
                var transferMagnitude = magnitude
                if outgoing,
                   ownerPaysGas,
                   coinType == SuiConstants.nativeCoinType,
                   let fee = networkFeeAtomic,
                   let totalDebit = UInt64(magnitude),
                   totalDebit >= fee {
                    transferMagnitude = String(totalDebit - fee)
                }
                guard transferMagnitude != "0" else { continue }
                let counterparty = Self.counterparty(
                    for: change,
                    in: node.balanceChanges,
                    owner: owner,
                    outgoing: outgoing,
                    sender: sender
                )
                result.append(
                    SuiHistoryItem(
                        id: "\(node.digest):\(index)",
                        transactionHash: node.digest,
                        timestamp: timestamp,
                        failed: node.status != "SUCCESS",
                        sender: sender,
                        counterparty: counterparty,
                        owner: owner,
                        metadata: token,
                        signedAtomicAmount: outgoing
                            ? "-\(transferMagnitude)"
                            : transferMagnitude,
                        amountText: try Self.userUnits(
                            atomic: transferMagnitude,
                            decimals: token.decimals
                        ),
                        networkFeeText: networkFeeText
                    )
                )
            }
        }
        return result.sorted { $0.timestamp > $1.timestamp }
    }

    nonisolated static func historyTimestamp(
        _ value: String?
    ) -> TimeInterval? {
        guard let value else { return nil }
        // iOS 18's default ISO8601 strategy rejects fractional seconds.
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let date = (try? fractional.parse(value))
            ?? (try? Date(value, strategy: .iso8601))
        return date?.timeIntervalSince1970
    }

    private static func counterparty(
        for change: SuiHistoryBalanceChange,
        in changes: [SuiHistoryBalanceChange],
        owner: String,
        outgoing: Bool,
        sender: String?
    ) -> String? {
        guard outgoing,
              let coinType = SuiCoinType.canonical(change.coinType)
        else {
            return sender
        }
        return changes.lazy.compactMap { candidate -> String? in
            guard !candidate.amount.hasPrefix("-"),
                  candidate.amount != "0",
                  SuiCoinType.canonical(candidate.coinType) == coinType,
                  let address = candidate.owner.flatMap(
                    SuiCoinType.canonicalAccountAddress
                  ),
                  address != owner
            else {
                return nil
            }
            return address
        }.first
    }

    private static func userUnits(
        atomic: String,
        decimals: Int
    ) throws -> String {
        guard ExactDecimalText.canonicalUnsignedInteger(atomic) == atomic,
              (0...255).contains(decimals)
        else {
            throw SuiProviderError.invalidResponse("quantity")
        }
        if atomic == "0" || decimals == 0 { return atomic }
        if atomic.count > decimals {
            let split = atomic.index(atomic.endIndex, offsetBy: -decimals)
            let value = String(atomic[..<split]) + "."
                + String(atomic[split...])
            return ExactDecimalText.canonicalUnsigned(value) ?? value
        }
        let value = "0." + String(
            repeating: "0",
            count: decimals - atomic.count
        ) + atomic
        return ExactDecimalText.canonicalUnsigned(value) ?? value
    }

    private static func failureCode(_ error: Error) -> String {
        (error as? SuiProviderError)?.diagnosticDescription
            ?? "sui_provider_unavailable"
    }

    private static func sanitizedMetadataText(
        _ value: String,
        maximumLength: Int
    ) -> String? {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty,
              trimmed.count <= maximumLength,
              trimmed.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else {
            return nil
        }
        return trimmed
    }

    private static func publicCode(_ value: String) -> String {
        String(
            value.lowercased().map {
                $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_"
            }
        )
        .split(separator: "_")
        .prefix(8)
        .joined(separator: "_")
    }

    private static let balancesQuery = """
    query Balances($address: SuiAddress!, $first: Int!, $after: String) {
      address(address: $address) {
        balances(first: $first, after: $after) {
          nodes { coinType { repr } totalBalance }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
    """

    private static let metadataQuery = """
    query Metadata($type: String!) {
      coinMetadata(coinType: $type) {
        name symbol decimals iconUrl
      }
    }
    """

    private static let historyQuery = """
    query History(
      $address: SuiAddress!,
      $last: Int!,
      $changeFirst: Int!,
      $before: String
    ) {
      address(address: $address) {
        transactions(last: $last, before: $before, relation: AFFECTED) {
          nodes {
            digest
            sender { address }
            effects {
              status
              timestamp
              gasEffects {
                gasSummary {
                  computationCost
                  storageCost
                  storageRebate
                  nonRefundableStorageFee
                }
              }
              balanceChanges(first: $changeFirst) {
                nodes { owner { address } coinType { repr } amount }
                pageInfo { hasNextPage endCursor }
              }
            }
          }
          pageInfo { hasPreviousPage startCursor }
        }
      }
    }
    """

    private static let balanceChangesQuery = """
    query BalanceChanges(
      $digest: String!,
      $first: Int!,
      $after: String
    ) {
      transactionEffects(digest: $digest) {
        balanceChanges(first: $first, after: $after) {
          nodes { owner { address } coinType { repr } amount }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
    """

    private static let transactionStatusQuery = """
    query TransactionStatus($digest: String!) {
      transactionEffects(digest: $digest) { status }
    }
    """

    private static let coinObjectsQuery = """
    query CoinObjects(
      $address: SuiAddress!,
      $type: String!,
      $first: Int!,
      $after: String
    ) {
      address(address: $address) {
        objects(first: $first, after: $after, filter: { type: $type }) {
          nodes { address version digest contents { json } }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
    """

    private static let epochQuery = """
    query Epoch { epoch { referenceGasPrice } }
    """

    private static let executeQuery = """
    mutation Execute($transaction: Base64!, $signature: Base64!) {
      executeTransaction(
        transactionDataBcs: $transaction,
        signatures: [$signature]
      ) {
        effects { digest status executionError { message } }
      }
    }
    """
}

private struct SuiHistoryLoad: Sendable {
    let transactions: [SuiHistoryTransaction]
    let isComplete: Bool
}

private struct SuiMetadataLoad: Sendable {
    let metadata: [String: SuiTokenMetadata]
    let failedCoinTypes: Set<String>
}

private struct SuiBalanceMapping: Sendable {
    let balances: [SuiAssetBalance]
    let failureCodes: [String]
}

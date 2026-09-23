import Foundation

private final class AptosIndexerTimestampParser: @unchecked Sendable {
    private let lock = NSLock()
    private let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        return formatter
    }()
    private let standard = ISO8601DateFormatter()

    func parse(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = Self.hasTimeZone(trimmed) ? trimmed : "\(trimmed)Z"
        lock.lock()
        defer { lock.unlock() }
        return fractional.date(from: normalized)
            ?? standard.date(from: normalized)
    }

    private static func hasTimeZone(_ value: String) -> Bool {
        guard let separator = value.firstIndex(of: "T") else { return false }
        let time = value[value.index(after: separator)...]
        return value.hasSuffix("Z")
            || time.contains("+")
            || time.contains("-")
    }
}

actor AptosAPIClient {
    static let shared = AptosAPIClient()
    private static let indexedTimestampParser = AptosIndexerTimestampParser()

    private struct ViewRequest: Encodable {
        let function: String
        let typeArguments: [String]
        let arguments: [String]

        enum CodingKeys: String, CodingKey {
            case function
            case typeArguments = "type_arguments"
            case arguments
        }
    }

    private struct BalanceLoad: Sendable {
        let balances: [AptosAssetBalance]
        let isAuthoritative: Bool
        let failures: [String]
    }

    private struct IndexedBalanceLoad: Sendable {
        let balances: [AptosAssetBalance]
        let isComplete: Bool
        let failureCodes: [String]
    }

    private struct HistoryLoad: Sendable {
        let items: [AptosHistoryItem]
        let isComplete: Bool
    }

    private enum IndexedBalanceOutcome: Sendable {
        case success(IndexedBalanceLoad)
        case failure(String)
        case cancelled
    }

    private enum HistoryOutcome: Sendable {
        case success(HistoryLoad)
        case partial(HistoryLoad, String)
        case failure(String)
        case cancelled
    }

    private enum TransactionDetailOutcome: Sendable {
        case loaded(Int64, AptosRESTTransactionResponse)
        case pruned
    }

    private let rest: AptosRESTTransport
    private let indexer: AptosIndexerTransport

    init(
        rest: AptosRESTTransport? = nil,
        indexer: AptosIndexerTransport? = nil
    ) {
        self.rest = rest ?? AptosRESTTransport()
        self.indexer = indexer ?? AptosIndexerTransport()
    }

    func loadSnapshot(
        material: AptosAccountMaterial,
        onBalances:
            (@Sendable (AptosWalletSnapshot) async throws -> Void)? = nil
    ) async throws -> AptosWalletSnapshot {
        guard let owner = AptosAddress.canonical(material.address) else {
            throw AptosProviderError.invalidAddress
        }
        // Balance discovery and history are independent. Start both indexer
        // reads before the fast REST-native request so one unavailable indexer
        // cannot impose two consecutive fallback windows on a refresh.
        async let indexedBalances = indexedBalanceOutcome(owner: owner)
        async let indexedHistory = historyOutcome(owner: owner)
        let nativeAtomic = try await nativeBalance(address: owner)
        let native = AptosAssetBalance(
            metadata: AptosTokenCatalog.native,
            amountText: try Self.userUnits(
                atomic: nativeAtomic,
                decimals: AptosConstants.decimals
            ),
            atomicAmount: nativeAtomic
        )
        let nativeSnapshot = AptosWalletSnapshot(
            material: material,
            balances: [native],
            history: [],
            balancesAreAuthoritative: false,
            historyIsAuthoritative: false,
            providerFailureCodes: [],
            successfulBalanceAssetIDs: [
                AptosConstants.nativeAssetID
            ]
        )
        try await onBalances?(nativeSnapshot)
        try Task.checkCancellation()

        let balanceLoad: BalanceLoad
        switch await indexedBalances {
        case let .success(indexed):
            balanceLoad = Self.mergedBalances(
                native: native,
                indexed: indexed
            )
        case let .failure(code):
            balanceLoad = BalanceLoad(
                balances: [native],
                isAuthoritative: false,
                failures: [code]
            )
        case .cancelled:
            throw CancellationError()
        }
        let successfulBalanceAssetIDs = Set(
            balanceLoad.balances.compactMap(\.assetID)
        )
        let partial = AptosWalletSnapshot(
            material: material,
            balances: balanceLoad.balances,
            history: [],
            balancesAreAuthoritative: balanceLoad.isAuthoritative,
            historyIsAuthoritative: false,
            providerFailureCodes: balanceLoad.failures,
            successfulBalanceAssetIDs: successfulBalanceAssetIDs
        )
        try await onBalances?(partial)
        try Task.checkCancellation()

        switch await indexedHistory {
        case let .success(history):
            return AptosWalletSnapshot(
                material: material,
                balances: balanceLoad.balances,
                history: history.items,
                balancesAreAuthoritative: balanceLoad.isAuthoritative,
                historyIsAuthoritative: history.isComplete,
                providerFailureCodes: balanceLoad.failures,
                successfulBalanceAssetIDs: successfulBalanceAssetIDs
            )
        case let .partial(history, code):
            return AptosWalletSnapshot(
                material: material,
                balances: balanceLoad.balances,
                history: history.items,
                balancesAreAuthoritative: balanceLoad.isAuthoritative,
                historyIsAuthoritative: false,
                providerFailureCodes: Array(
                    Set(balanceLoad.failures + [code])
                ).sorted(),
                successfulBalanceAssetIDs: successfulBalanceAssetIDs
            )
        case .cancelled:
            throw CancellationError()
        case let .failure(code):
            return AptosWalletSnapshot(
                material: material,
                balances: balanceLoad.balances,
                history: [],
                balancesAreAuthoritative: balanceLoad.isAuthoritative,
                historyIsAuthoritative: false,
                providerFailureCodes: Array(
                    Set(balanceLoad.failures + [code])
                ).sorted(),
                successfulBalanceAssetIDs: successfulBalanceAssetIDs
            )
        }
    }

    func nativeBalance(address: String) async throws -> String {
        guard let owner = AptosAddress.canonical(address) else {
            throw AptosProviderError.invalidAddress
        }
        let result: [String] = try await rest.post(
            path: "view",
            body: ViewRequest(
                function: "0x1::coin::balance",
                typeArguments: [AptosConstants.nativeCoinType],
                arguments: [owner]
            )
        )
        guard let value = result.first,
              let canonical = ExactDecimalText.canonicalUnsignedInteger(value)
        else { throw AptosProviderError.invalidResponse("native_balance") }
        return canonical
    }

    func assetSendState(
        address: String,
        assetType: String
    ) async throws -> AptosAssetSendState {
        guard let owner = AptosAddress.canonical(address) else {
            throw AptosProviderError.invalidAddress
        }
        guard let canonicalAsset = AptosAssetType.canonical(assetType) else {
            throw AptosProviderError.invalidAssetType
        }
        let response: AptosIndexerBalancesResponse = try await indexer.request(
            query: Self.assetBalanceQuery,
            variables: [
                "owner": .string(owner),
                "assetType": .string(canonicalAsset)
            ]
        )
        guard response.currentFungibleAssetBalances.count <= 1 else {
            throw AptosProviderError.invalidResponse(
                "asset_balance_duplicate"
            )
        }
        guard let item = response.currentFungibleAssetBalances.first else {
            return AptosAssetSendState(
                atomicAmount: "0",
                isFrozen: false
            )
        }
        guard item.isPrimary,
              AptosAddress.canonical(item.storageID) == item.storageID,
              AptosAssetType.canonical(item.assetType) == canonicalAsset,
              let amount = ExactDecimalText.canonicalUnsignedInteger(
                  item.amount
              )
        else {
            throw AptosProviderError.invalidResponse("asset_balance")
        }
        return AptosAssetSendState(
            atomicAmount: amount,
            isFrozen: item.isFrozen
        )
    }

    func transactionStatus(
        hash: String
    ) async throws -> SendTransactionNetworkStatus {
        let normalizedHash = hash.lowercased()
        guard normalizedHash.hasPrefix("0x"),
              SendTransactionStatusValidation.isHexHash(
                  normalizedHash,
                  byteCount: 32,
                  allowsPrefix: true
              ) else {
            throw SendTransactionStatusProviderError
                .invalidTransactionHash(networkID: AptosConstants.networkID)
        }
        let response: AptosTransactionStatusResponse
        do {
            response = try await rest.get(
                path: "transactions/by_hash/\(normalizedHash)"
            )
        } catch let error as AptosProviderError {
            if case .http(status: 404, code: _) = error {
                return .notFound
            }
            throw error
        }
        return try Self.transactionStatus(
            from: response,
            expectedHash: normalizedHash
        )
    }

    static func transactionStatus(
        from response: AptosTransactionStatusResponse,
        expectedHash: String
    ) throws -> SendTransactionNetworkStatus {
        guard response.hash.caseInsensitiveCompare(expectedHash)
                == .orderedSame else {
            throw AptosProviderError.invalidResponse("transaction_hash")
        }
        if response.type == "pending_transaction" { return .pending }
        guard let succeeded = response.success else {
            throw AptosProviderError.invalidResponse("transaction_status")
        }
        return succeeded ? .confirmed : .failed
    }

    func accountState(address: String) async throws -> AptosAccountState {
        guard let owner = AptosAddress.canonical(address) else {
            throw AptosProviderError.invalidAddress
        }
        do {
            let response: AptosRESTAccountResponse = try await rest.get(
                path: "accounts/\(owner)"
            )
            guard let sequence = UInt64(response.sequenceNumber) else {
                throw AptosProviderError.invalidResponse("sequence")
            }
            return AptosAccountState(
                sequenceNumber: sequence,
                authenticationKey: response.authenticationKey
            )
        } catch let error as AptosProviderError {
            if case let .http(status, _) = error, status == 404 {
                return AptosAccountState(
                    sequenceNumber: 0,
                    authenticationKey: owner
                )
            }
            throw error
        }
    }

    func gasEstimate() async throws -> AptosGasEstimate {
        let response: AptosRESTGasResponse = try await rest.get(
            path: "estimate_gas_price"
        )
        guard response.deprioritizedGasEstimate > 0,
              response.gasEstimate >= response.deprioritizedGasEstimate,
              response.prioritizedGasEstimate >= response.gasEstimate
        else { throw AptosProviderError.invalidResponse("gas_price") }
        return AptosGasEstimate(
            deprioritized: response.deprioritizedGasEstimate,
            standard: response.gasEstimate,
            prioritized: response.prioritizedGasEstimate
        )
    }

    func submit(signedTransaction: Data) async throws -> AptosSubmitResult {
        try await rest.submit(signedTransaction: signedTransaction)
    }

    func simulate(
        signedTransaction: Data
    ) async throws -> AptosSimulationResult {
        try await rest.simulate(signedTransaction: signedTransaction)
    }

    private static func mergedBalances(
        native: AptosAssetBalance,
        indexed: IndexedBalanceLoad
    ) -> BalanceLoad {
        var byAssetID: [String: AptosAssetBalance] = [:]
        for balance in [native] + indexed.balances {
            if let assetID = AptosAssetType.assetID(
                balance.metadata.assetType
            ) {
                byAssetID[assetID] = balance
            }
        }
        byAssetID[AptosConstants.nativeAssetID] = native
        return BalanceLoad(
            balances: byAssetID.values.sorted {
                if $0.metadata.rank != $1.metadata.rank {
                    return $0.metadata.rank < $1.metadata.rank
                }
                return $0.metadata.symbol.localizedStandardCompare(
                    $1.metadata.symbol
                ) == .orderedAscending
            },
            isAuthoritative: indexed.isComplete,
            failures: indexed.failureCodes
        )
    }

    private func indexedBalanceOutcome(
        owner: String
    ) async -> IndexedBalanceOutcome {
        do {
            return .success(try await indexerBalances(owner: owner))
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(Self.failureCode(error))
        }
    }

    private func historyOutcome(owner: String) async -> HistoryOutcome {
        do {
            return .success(try await history(owner: owner))
        } catch is CancellationError {
            return .cancelled
        } catch {
            let indexerFailure = Self.failureCode(error)
            do {
                return .partial(
                    try await outgoingRESTHistory(owner: owner),
                    indexerFailure
                )
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failure(
                    [indexerFailure, Self.failureCode(error)]
                        .sorted()
                        .joined(separator: "+")
                )
            }
        }
    }

    /// Aptos REST exposes transactions submitted by an account, but it cannot
    /// enumerate incoming transfers or all fungible-asset activity. This is a
    /// deliberately non-authoritative fallback that recovers only transfer
    /// entry functions whose asset, recipient, and amount can be proven from
    /// the signed payload. The caller retains the indexer failure so cached
    /// incoming/token history is never destructively replaced.
    private func outgoingRESTHistory(owner: String) async throws -> HistoryLoad {
        let account = try await accountState(address: owner)
        guard account.sequenceNumber > 0 else {
            return HistoryLoad(items: [], isComplete: false)
        }
        let limit = UInt64(AptosConstants.historyPageSize)
        let start = account.sequenceNumber > limit
            ? account.sequenceNumber - limit
            : 0
        let transactions: [AptosRESTTransactionResponse] = try await rest.get(
            path: "accounts/\(owner)/transactions",
            query: [
                URLQueryItem(name: "start", value: String(start)),
                URLQueryItem(name: "limit", value: String(limit))
            ]
        )
        let items = try transactions.compactMap { transaction in
            try Self.outgoingRESTHistoryItem(
                transaction: transaction,
                owner: owner
            )
        }
        return HistoryLoad(
            items: items.sorted { $0.transactionVersion > $1.transactionVersion },
            isComplete: false
        )
    }

    private static func outgoingRESTHistoryItem(
        transaction: AptosRESTTransactionResponse,
        owner: String
    ) throws -> AptosHistoryItem? {
        guard transaction.sender.flatMap(AptosAddress.canonical) == owner,
              let version = Int64(transaction.version),
              let payload = transaction.payload,
              let function = payload.function?.lowercased(),
              let recipient = payload.arguments.first.flatMap(
                AptosAddress.canonical
              ),
              payload.arguments.count >= 2,
              let atomic = ExactDecimalText.canonicalUnsignedInteger(
                payload.arguments[1]
              ),
              isNativeTransferFunction(
                function,
                typeArguments: payload.typeArguments
              )
        else { return nil }
        let amount = try userUnits(
            atomic: atomic,
            decimals: AptosConstants.decimals
        )
        return AptosHistoryItem(
            id: "\(version):rest-outgoing",
            transactionVersion: version,
            transactionHash: transaction.hash.lowercased(),
            timestamp: timestamp(
                "",
                fallbackMicroseconds: transaction.timestamp
            ),
            failed: !transaction.success,
            sender: owner,
            recipient: recipient,
            owner: owner,
            metadata: AptosTokenCatalog.native,
            signedAmountText: "-\(amount)",
            networkFeeText: try feeText(transaction: transaction),
            entryFunction: payload.function
        )
    }

    private static func isNativeTransferFunction(
        _ function: String,
        typeArguments: [String]
    ) -> Bool {
        if function == "0x1::aptos_account::transfer" {
            return true
        }
        let typedTransfer = function == "0x1::aptos_account::transfer_coins"
            || function == "0x1::coin::transfer"
        guard typedTransfer,
              let firstType = typeArguments.first.flatMap(
                AptosAssetType.canonical
              )
        else { return false }
        return firstType == AptosConstants.nativeCoinType
    }

    private func indexerBalances(
        owner: String
    ) async throws -> IndexedBalanceLoad {
        var cursor = ""
        var result: [AptosAssetBalance] = []
        var seenAssetIDs = Set<String>()
        var seenStorageIDs = Set<String>()
        var failureCodes = Set<String>()
        for _ in 0..<AptosConstants.maximumBalancePages {
            let page: AptosIndexerBalancesResponse = try await indexer.request(
                query: Self.balancesQuery,
                variables: [
                    "owner": .string(owner),
                    "limit": .integer(AptosConstants.balancePageSize),
                    "afterAsset": .string(cursor)
                ]
            )
            var previousAssetType = cursor
            for item in page.currentFungibleAssetBalances {
                guard item.assetType > previousAssetType else {
                    failureCodes.insert(
                        "aptos_balance_pagination_order_invalid"
                    )
                    return IndexedBalanceLoad(
                        balances: result,
                        isComplete: false,
                        failureCodes: failureCodes.sorted()
                    )
                }
                previousAssetType = item.assetType
                guard let storageID = AptosAddress.canonical(item.storageID),
                      storageID == item.storageID else {
                    failureCodes.insert("aptos_balance_item_invalid")
                    return IndexedBalanceLoad(
                        balances: result,
                        isComplete: false,
                        failureCodes: failureCodes.sorted()
                    )
                }
                guard seenStorageIDs.insert(storageID).inserted else {
                    failureCodes.insert("aptos_balance_storage_duplicate")
                    return IndexedBalanceLoad(
                        balances: result,
                        isComplete: false,
                        failureCodes: failureCodes.sorted()
                    )
                }
                guard item.isPrimary,
                      let atomic = ExactDecimalText.canonicalUnsignedInteger(
                    item.amount
                ), let metadata = AptosTokenCatalog.metadata(
                    assetType: item.assetType,
                    provider: item.metadata
                ), let assetID = AptosAssetType.assetID(
                    metadata.assetType
                ) else {
                    failureCodes.insert("aptos_balance_item_invalid")
                    continue
                }
                guard seenAssetIDs.insert(assetID).inserted else {
                    failureCodes.insert(
                        "aptos_balance_primary_asset_duplicate"
                    )
                    continue
                }
                result.append(
                    AptosAssetBalance(
                        metadata: metadata,
                        amountText: try Self.userUnits(
                            atomic: atomic,
                            decimals: metadata.decimals
                        ),
                        atomicAmount: atomic
                    )
                )
            }
            guard page.currentFungibleAssetBalances.count
                    == AptosConstants.balancePageSize else {
                return IndexedBalanceLoad(
                    balances: result,
                    isComplete: failureCodes.isEmpty,
                    failureCodes: failureCodes.sorted()
                )
            }
            guard let nextCursor = page.currentFungibleAssetBalances.last?
                .assetType, nextCursor != cursor else {
                failureCodes.insert("aptos_balance_pagination_cursor_invalid")
                return IndexedBalanceLoad(
                    balances: result,
                    isComplete: false,
                    failureCodes: failureCodes.sorted()
                )
            }
            cursor = nextCursor
        }
        failureCodes.insert("aptos_balance_pagination_incomplete")
        return IndexedBalanceLoad(
            balances: result,
            isComplete: false,
            failureCodes: failureCodes.sorted()
        )
    }

    private func history(owner: String) async throws -> HistoryLoad {
        var offset = 0
        var activities: [AptosIndexerActivity] = []
        var isComplete = false
        for _ in 0..<AptosConstants.maximumHistoryPages {
            let page: AptosIndexerActivitiesResponse = try await indexer.request(
                query: Self.historyQuery,
                variables: [
                    "owner": .string(owner),
                    "limit": .integer(AptosConstants.historyPageSize),
                    "offset": .integer(offset)
                ]
            )
            activities.append(contentsOf: page.fungibleAssetActivities)
            guard page.fungibleAssetActivities.count
                    == AptosConstants.historyPageSize else {
                isComplete = true
                break
            }
            offset += AptosConstants.historyPageSize
        }
        let versions = Set(activities.compactMap { Int64($0.transactionVersion) })
        let transactions = try await transactionDetails(versions: versions)
        var result: [AptosHistoryItem] = []
        for activity in activities {
            guard let version = Int64(activity.transactionVersion),
                  let eventIndex = Int64(activity.eventIndex),
                  let atomicRaw = activity.amount,
                  let atomic = Self.absoluteInteger(atomicRaw),
                  let rawType = activity.assetType
                    ?? activity.metadata?.assetType,
                  let metadata = AptosTokenCatalog.metadata(
                    assetType: rawType,
                    provider: activity.metadata
                  )
            else { continue }
            let transaction = transactions[version]
            let outgoing = activity.type.lowercased().contains("withdraw")
                || atomicRaw.hasPrefix("-")
            let recipient = outgoing
                ? transaction?.payload?.arguments.first.flatMap(
                    AptosAddress.canonical
                  )
                : owner
            let amount = try Self.userUnits(
                atomic: atomic,
                decimals: metadata.decimals
            )
            let fee = try transaction.flatMap {
                try Self.feeText(transaction: $0)
            }
            result.append(
                AptosHistoryItem(
                    id: "\(version):\(eventIndex)",
                    transactionVersion: version,
                    // Aptos Explorer accepts an immutable ledger version as
                    // a transaction reference when an archival hash is no
                    // longer available from the configured fullnodes.
                    transactionHash: transaction?.hash.lowercased()
                        ?? String(version),
                    timestamp: Self.timestamp(
                        activity.timestamp,
                        fallbackMicroseconds: transaction?.timestamp
                    ),
                    failed: !activity.isTransactionSuccess
                        || !(transaction?.success ?? true),
                    sender: transaction?.sender.flatMap(
                        AptosAddress.canonical
                    ) ?? (outgoing ? owner : nil),
                    recipient: recipient,
                    owner: owner,
                    metadata: metadata,
                    signedAmountText: outgoing ? "-\(amount)" : amount,
                    networkFeeText: fee,
                    entryFunction: activity.entryFunction
                        ?? transaction?.payload?.function
                )
            )
        }
        return HistoryLoad(
            items: result.sorted {
                $0.transactionVersion > $1.transactionVersion
            },
            isComplete: isComplete
        )
    }

    private func transactionDetails(
        versions: Set<Int64>
    ) async throws -> [Int64: AptosRESTTransactionResponse] {
        let rest = rest
        var result: [Int64: AptosRESTTransactionResponse] = [:]
        let ordered = versions.sorted(by: >)
        for start in stride(from: 0, to: ordered.count, by: 8) {
            let end = min(start + 8, ordered.count)
            let batch = Array(ordered[start..<end])
            let values = try await withThrowingTaskGroup(
                of: TransactionDetailOutcome.self
            ) { group in
                for version in batch {
                    group.addTask {
                        do {
                            let response: AptosRESTTransactionResponse =
                                try await rest.get(
                                    path: "transactions/by_version/\(version)"
                                )
                            guard Int64(response.version) == version,
                                  Self.isCanonicalTransactionHash(
                                    response.hash
                                  ) else {
                                throw AptosProviderError.invalidResponse(
                                    "transaction_detail"
                                )
                            }
                            return .loaded(version, response)
                        } catch let error as AptosProviderError {
                            // Public fullnodes intentionally prune historical
                            // transaction bodies. The indexer activity remains
                            // authoritative for amount, direction, status, and
                            // timestamp, so this exact response is not a
                            // provider outage.
                            if Self.isPrunedTransactionDetail(error) {
                                return .pruned
                            }
                            throw error
                        }
                    }
                }
                var loaded: [TransactionDetailOutcome] = []
                for try await item in group { loaded.append(item) }
                return loaded
            }
            for value in values {
                guard case let .loaded(version, transaction) = value else {
                    continue
                }
                result[version] = transaction
            }
        }
        return result
    }

    private nonisolated static func isPrunedTransactionDetail(
        _ error: AptosProviderError
    ) -> Bool {
        guard case let .http(status, code) = error else { return false }
        return status == 410 && code == "version_pruned"
    }

    private nonisolated static func isCanonicalTransactionHash(
        _ value: String
    ) -> Bool {
        value.hasPrefix("0x")
            && value.count == 66
            && value.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    static func userUnits(atomic: String, decimals: Int) throws -> String {
        guard let value = ExactDecimalText.canonicalUnsignedInteger(atomic),
              decimals >= 0
        else { throw AptosProviderError.invalidResponse("amount") }
        if decimals == 0 { return value }
        let padded = value.count <= decimals
            ? String(repeating: "0", count: decimals - value.count + 1) + value
            : value
        let split = padded.index(padded.endIndex, offsetBy: -decimals)
        let whole = String(padded[..<split])
        let fraction = String(
            padded[split...]
                .reversed()
                .drop { $0 == "0" }
                .reversed()
        )
        return fraction.isEmpty ? whole : "\(whole).\(fraction)"
    }

    private static func absoluteInteger(_ value: String) -> String? {
        ExactDecimalText.canonicalUnsignedInteger(
            value.hasPrefix("-") ? String(value.dropFirst()) : value
        )
    }

    private static func feeText(
        transaction: AptosRESTTransactionResponse
    ) throws -> String? {
        guard let gasUsed = transaction.gasUsed.flatMap(UInt64.init),
              let price = transaction.gasUnitPrice.flatMap(UInt64.init)
        else { return nil }
        let product = gasUsed.multipliedReportingOverflow(by: price)
        guard !product.overflow else {
            throw AptosProviderError.invalidResponse("fee_overflow")
        }
        return try userUnits(
            atomic: String(product.partialValue),
            decimals: AptosConstants.decimals
        )
    }

    private static func timestamp(
        _ indexed: String,
        fallbackMicroseconds: String?
    ) -> Double {
        if let date = indexedTimestampParser.parse(indexed) {
            return date.timeIntervalSince1970
        }
        if let micros = fallbackMicroseconds.flatMap(Int64.init), micros >= 0 {
            return Double(micros) / 1_000_000
        }
        return 0
    }

    private static func failureCode(_ error: Error) -> String {
        if let error = error as? AptosProviderError {
            return error.diagnosticDescription
        }
        if let error = error as? ProviderReliabilityError {
            return "aptos_\(error.diagnosticDescription)"
        }
        if let error = error as? URLError {
            return "aptos_url_\(error.code.rawValue)"
        }
        return "aptos_provider_unavailable"
    }

    static let balancesQuery = """
    query AptosBalances(
      $owner: String!
      $limit: Int!
      $afterAsset: String!
    ) {
      current_fungible_asset_balances(
        where: {
          owner_address: { _eq: $owner }
          asset_type: { _gt: $afterAsset }
          is_primary: { _eq: true }
        }
        order_by: { asset_type: asc }
        limit: $limit
      ) {
        storage_id
        amount
        asset_type
        token_standard
        is_primary
        is_frozen
        metadata {
          asset_type
          name
          symbol
          decimals
          icon_uri
          token_standard
        }
      }
    }
    """

    private static let assetBalanceQuery = """
    query AptosAssetBalance($owner: String!, $assetType: String!) {
      current_fungible_asset_balances(
        where: {
          owner_address: { _eq: $owner }
          asset_type: { _eq: $assetType }
          is_primary: { _eq: true }
        }
        order_by: { storage_id: asc }
        limit: 2
      ) {
        storage_id
        amount
        asset_type
        token_standard
        is_primary
        is_frozen
      }
    }
    """

    private static let historyQuery = """
    query AptosActivities($owner: String!, $limit: Int!, $offset: Int!) {
      fungible_asset_activities(
        where: {
          owner_address: { _eq: $owner }
          is_gas_fee: { _eq: false }
        }
        order_by: [
          { transaction_version: desc },
          { event_index: desc }
        ]
        limit: $limit
        offset: $offset
      ) {
        transaction_version
        event_index
        owner_address
        asset_type
        amount
        type
        is_transaction_success
        entry_function_id_str
        transaction_timestamp
        metadata {
          asset_type
          name
          symbol
          decimals
          icon_uri
          token_standard
        }
      }
    }
    """
}

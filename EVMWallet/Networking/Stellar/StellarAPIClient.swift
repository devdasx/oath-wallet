import Foundation

actor StellarAPIClient {
    static let shared = StellarAPIClient()

    private struct BalanceLoad: Sendable {
        let balances: [StellarAssetBalance]
    }

    private struct HistoryLoad: Sendable {
        let items: [StellarHistoryItem]
        let isAuthoritative: Bool
        let failures: [String]
    }

    private let transport: StellarHorizonTransport

    init(transport: StellarHorizonTransport = StellarHorizonTransport()) {
        self.transport = transport
    }

    func loadSnapshot(
        material: StellarAccountMaterial,
        onBalances:
            (@Sendable (StellarWalletSnapshot) async throws -> Void)? = nil
    ) async throws -> StellarWalletSnapshot {
        guard StellarAddress.validated(material.address) != nil else {
            throw StellarProviderError.invalidAddress
        }
        let load = try await balances(address: material.address)
        let partial = StellarWalletSnapshot(
            material: material,
            balances: load.balances,
            history: [],
            balancesAreAuthoritative: true,
            historyIsAuthoritative: false,
            providerFailureCodes: [],
            successfulBalanceAssetIDs: Set(
                load.balances.map(\.assetID)
            )
        )
        try await onBalances?(partial)
        try Task.checkCancellation()
        do {
            let historyLoad = try await history(address: material.address)
            return StellarWalletSnapshot(
                material: material,
                balances: load.balances,
                history: historyLoad.items,
                balancesAreAuthoritative: true,
                historyIsAuthoritative: historyLoad.isAuthoritative,
                providerFailureCodes: historyLoad.failures,
                successfulBalanceAssetIDs: Set(
                    load.balances.map(\.assetID)
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return StellarWalletSnapshot(
                material: material,
                balances: load.balances,
                history: [],
                balancesAreAuthoritative: true,
                historyIsAuthoritative: false,
                providerFailureCodes: [Self.failureCode(error)],
                successfulBalanceAssetIDs: Set(
                    load.balances.map(\.assetID)
                )
            )
        }
    }

    func transactionStatus(
        hash: String
    ) async throws -> SendTransactionNetworkStatus {
        let normalizedHash = hash.lowercased()
        guard SendTransactionStatusValidation.isHexHash(
            normalizedHash,
            byteCount: 32,
            allowsPrefix: false
        ) else {
            throw SendTransactionStatusProviderError
                .invalidTransactionHash(
                    networkID: StellarConstants.networkID
                )
        }
        guard let transaction = try await transport.optionalTransaction(
            normalizedHash
        ) else {
            return .notFound
        }
        return try Self.transactionStatus(
            from: transaction,
            expectedHash: normalizedHash
        )
    }

    static func transactionStatus(
        from transaction: StellarHorizonTransaction,
        expectedHash: String
    ) throws -> SendTransactionNetworkStatus {
        guard transaction.hash.caseInsensitiveCompare(expectedHash)
                == .orderedSame,
              transaction.ledger > 0 else {
            throw StellarProviderError.invalidResponse(
                "transaction_status"
            )
        }
        return transaction.successful ? .confirmed : .failed
    }

    func accountState(address: String) async throws -> StellarAccountState? {
        guard StellarAddress.validated(address) != nil else {
            throw StellarProviderError.invalidAddress
        }
        guard let account = try await transport.account(address) else {
            return nil
        }
        guard StellarAddress.validated(account.accountID) == address else {
            throw StellarProviderError.invalidResponse("account_identity")
        }
        return try Self.state(account)
    }

    /// Account activation and minimum balances depend on the current ledger's
    /// reserve, independently of the fee rate saved by the home screen.
    func baseReserveStroops() async throws -> String {
        let page = try await transport.latestLedger()
        guard let ledger = page.embedded.records.first, ledger.baseReserveInStroops > 0 else {
            throw StellarProviderError.invalidResponse("network_reserve")
        }
        return String(ledger.baseReserveInStroops)
    }

    func networkState(usingSavedFee value: String) async throws -> StellarNetworkState {
        guard let fee = Int64(value), fee >= StellarConstants.minimumFeeStroops,
              fee <= Int64(UInt32.max) else {
            throw StellarProviderError.invalidResponse("saved_fee")
        }
        return StellarNetworkState(baseReserveStroops: try await baseReserveStroops(), recommendedFeeStroops: fee)
    }

    func networkState() async throws -> StellarNetworkState {
        async let feeStats = transport.feeStats()
        async let ledgers = transport.latestLedger()
        let (fee, ledgerPage) = try await (feeStats, ledgers)
        guard let ledger = ledgerPage.embedded.records.first,
              ledger.baseReserveInStroops > 0,
              let recommended = Int64(fee.feeCharged.p95),
              recommended > 0
        else { throw StellarProviderError.invalidResponse("network_state") }
        return StellarNetworkState(
            baseReserveStroops: String(ledger.baseReserveInStroops),
            recommendedFeeStroops: max(
                StellarConstants.minimumFeeStroops,
                recommended
            )
        )
    }

    func submit(xdr: String) async throws -> StellarSubmitResult {
        guard !xdr.isEmpty else {
            throw StellarProviderError.invalidResponse("transaction_xdr")
        }
        let response = try await transport.submit(xdr: xdr)
        return StellarSubmitResult(
            transactionHash: response.hash,
            successful: response.successful,
            ledger: response.ledger
        )
    }

    private func balances(address: String) async throws -> BalanceLoad {
        guard let account = try await transport.account(address) else {
            return BalanceLoad(
                balances: [
                    StellarAssetBalance(
                        metadata: nil,
                        amountText: "0",
                        atomicAmount: "0"
                    )
                ]
            )
        }
        guard StellarAddress.validated(account.accountID) == address else {
            throw StellarProviderError.invalidResponse("account_identity")
        }
        var values: [StellarAssetBalance] = []
        for item in account.balances {
            let atomic = try StellarAmount.atomicUnits(userUnits: item.balance)
            if item.assetType == "native" {
                values.append(
                    StellarAssetBalance(
                        metadata: nil,
                        amountText: try StellarAmount.userUnits(atomic: atomic),
                        atomicAmount: atomic
                    )
                )
            } else if item.assetType == "liquidity_pool_shares" {
                // Liquidity-pool shares are not transferable Stellar assets.
                // Ignore them without invalidating the account's real balances.
                continue
            } else if (item.assetType == "credit_alphanum4"
                        || item.assetType == "credit_alphanum12"),
                      let code = item.assetCode,
                      let issuer = item.assetIssuer,
                      let metadata = StellarTokenCatalog.metadata(
                          code: code,
                          issuer: issuer
                      ) {
                values.append(
                    StellarAssetBalance(
                        metadata: metadata,
                        amountText: try StellarAmount.userUnits(atomic: atomic),
                        atomicAmount: atomic
                    )
                )
            } else {
                throw StellarProviderError.invalidResponse("asset_identity")
            }
        }
        // Horizon always includes the native balance for an existing account.
        // Treat its absence as an incomplete provider response, never as proof
        // that the account's XLM balance became zero. A real missing account is
        // handled by the explicit HTTP 404 branch above.
        guard values.contains(where: { $0.metadata == nil }) else {
            throw StellarProviderError.invalidResponse(
                "native_balance_missing"
            )
        }
        return BalanceLoad(balances: values)
    }

    private func history(address: String) async throws -> HistoryLoad {
        var records: [StellarHorizonPaymentPage.Payment] = []
        var cursor: String?
        var exhausted = false
        for _ in 0..<StellarConstants.maximumHistoryPages {
            let page = try await transport.payments(
                address: address,
                cursor: cursor
            )
            let supported = page.embedded.records.filter {
                $0.type == "payment"
                    || $0.type == "create_account"
                    || $0.type == "path_payment_strict_receive"
                    || $0.type == "path_payment_strict_send"
            }
            records.append(contentsOf: supported)
            guard page.embedded.records.count
                    == StellarConstants.historyPageSize,
                  let next = page.embedded.records.last?.pagingToken,
                  next != cursor
            else {
                exhausted = true
                break
            }
            cursor = next
        }

        var transactions = Dictionary(
            records.compactMap { record in
                record.transaction.map {
                    (record.transactionHash, $0)
                }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let allMissingHashes = Array(
            Set(records.map(\.transactionHash)).subtracting(
                transactions.keys
            )
        )
        let missingHashes = allMissingHashes.prefix(
            StellarConstants.maximumTransactionEnrichment
        )
        var failures: [String] = []
        let enrichmentComplete = allMissingHashes.count
            <= StellarConstants.maximumTransactionEnrichment
        await withTaskGroup(
            of: (String, Result<StellarHorizonTransaction, Error>).self
        ) { group in
            for hash in missingHashes {
                group.addTask { [transport] in
                    do { return (hash, .success(try await transport.transaction(hash))) }
                    catch { return (hash, .failure(error)) }
                }
            }
            for await (hash, result) in group {
                switch result {
                case let .success(transaction): transactions[hash] = transaction
                case let .failure(error): failures.append(Self.failureCode(error))
                }
            }
        }

        let items = try records.compactMap { record -> StellarHistoryItem? in
            guard let transfer = try Self.transfer(record, address: address)
            else { return nil }
            let transaction = transactions[record.transactionHash]
            return StellarHistoryItem(
                id: record.id,
                transactionHash: record.transactionHash,
                timestamp: try Self.timestamp(record.createdAt),
                failed: transaction.map { !$0.successful } ?? false,
                sender: transfer.sender,
                recipient: transfer.recipient,
                metadata: transfer.metadata,
                signedAmountText: transfer.amount,
                networkFeeStroops: transaction?.feeCharged,
                ledgerIndex: transaction?.ledger,
                sourceSequence: transaction.flatMap {
                    Int64($0.sourceAccountSequence)
                },
                memo: transaction?.memo
            )
        }
        return HistoryLoad(
            items: items,
            isAuthoritative: exhausted
                && enrichmentComplete
                && failures.isEmpty,
            failures: Array(Set(failures)).sorted()
        )
    }

    private static func state(
        _ account: StellarHorizonAccount
    ) throws -> StellarAccountState {
        guard let sequence = Int64(account.sequence) else {
            throw StellarProviderError.invalidResponse("sequence")
        }
        var native = "0"
        var liabilities = "0"
        var trustlines: [StellarTrustlineState] = []
        for balance in account.balances {
            if balance.assetType == "native" {
                native = try StellarAmount.atomicUnits(userUnits: balance.balance)
                liabilities = try StellarAmount.atomicUnits(
                    userUnits: balance.sellingLiabilities
                )
            } else if balance.assetType == "liquidity_pool_shares" {
                continue
            } else if (balance.assetType == "credit_alphanum4"
                        || balance.assetType == "credit_alphanum12"),
                      let code = balance.assetCode,
                      let issuer = balance.assetIssuer,
                      let identity = StellarAssetIdentity.validated(
                          code: code,
                          issuer: issuer
                      ),
                      let buyingLiabilities = balance.buyingLiabilities,
                      let limit = balance.limit {
                trustlines.append(
                    StellarTrustlineState(
                        identity: identity,
                        balanceStroops: try StellarAmount.atomicUnits(
                            userUnits: balance.balance
                        ),
                        sellingLiabilitiesStroops:
                            try StellarAmount.atomicUnits(
                                userUnits: balance.sellingLiabilities
                            ),
                        buyingLiabilitiesStroops:
                            try StellarAmount.atomicUnits(
                                userUnits: buyingLiabilities
                            ),
                        limitStroops: try StellarAmount.atomicUnits(
                            userUnits: limit
                        ),
                        authorized: balance.isAuthorized ?? false
                    )
                )
            } else {
                throw StellarProviderError.invalidResponse("asset_identity")
            }
        }
        return StellarAccountState(
            address: account.accountID,
            sequence: sequence,
            nativeBalanceStroops: native,
            nativeSellingLiabilitiesStroops: liabilities,
            subentryCount: account.subentryCount,
            numSponsoring: account.numSponsoring,
            numSponsored: account.numSponsored,
            trustlines: trustlines
        )
    }

    private static func transfer(
        _ record: StellarHorizonPaymentPage.Payment,
        address: String
    ) throws -> (
        sender: String,
        recipient: String,
        metadata: StellarTokenMetadata?,
        amount: String
    )? {
        let sender: String
        let recipient: String
        let rawAmount: String
        if record.type == "create_account" {
            guard let source = record.sourceAccount,
                  let account = record.account,
                  let amount = record.startingBalance
            else { return nil }
            sender = source
            recipient = account
            rawAmount = amount
        } else {
            guard let from = record.from, let to = record.to,
                  let amount = record.amount else { return nil }
            sender = from
            recipient = to
            rawAmount = amount
        }
        let outgoing = sender == address
        let metadata: StellarTokenMetadata?
        if record.assetType == "native" || record.type == "create_account" {
            metadata = nil
        } else if let code = record.assetCode,
                  let issuer = record.assetIssuer,
                  let value = StellarTokenCatalog.metadata(
                    code: code,
                    issuer: issuer
                  ) {
            metadata = value
        } else { return nil }
        let atomic = try StellarAmount.atomicUnits(userUnits: rawAmount)
        let amount = try StellarAmount.userUnits(atomic: atomic)
        return (
            sender,
            recipient,
            metadata,
            outgoing && amount != "0" ? "-\(amount)" : amount
        )
    }

    private static func timestamp(_ value: String) throws -> Double {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        if let date = fractional.date(from: value)
            ?? ISO8601DateFormatter().date(from: value) {
            return date.timeIntervalSince1970
        }
        throw StellarProviderError.invalidResponse("created_at")
    }

    private static func failureCode(_ error: Error) -> String {
        if let provider = error as? StellarProviderError {
            return provider.diagnosticDescription
        }
        return "stellar_\(StellarErrorCode.sanitize(String(describing: error)))"
    }
}

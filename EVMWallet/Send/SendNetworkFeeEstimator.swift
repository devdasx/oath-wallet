import Foundation
import WalletCore

struct SendNetworkFeeEstimate: Sendable {
    enum Source: Sendable {
        case exact
        case transactionTemplate
    }

    let atomicAmount: String
    let nativeDecimals: Int
    let source: Source
    let nativeTransferAmountAtomic: String?
    let nativeMaximumInputs: [SendBitcoinUTXO]?

    init(
        atomicAmount: String,
        nativeDecimals: Int,
        source: Source = .exact,
        nativeTransferAmountAtomic: String? = nil,
        nativeMaximumInputs: [SendBitcoinUTXO]? = nil
    ) {
        self.atomicAmount = atomicAmount
        self.nativeDecimals = nativeDecimals
        self.source = source
        self.nativeTransferAmountAtomic = nativeTransferAmountAtomic
        self.nativeMaximumInputs = nativeMaximumInputs
    }

    func applyingNativeAmount(to draft: SendDraft) -> SendDraft {
        guard draft.asset.isNative, let nativeTransferAmountAtomic else { return draft }
        // Authorization displays and commits this recipient amount. A later
        // balance increase must not raise it above the amount reviewed here.
        let adjusted = draft.replacing(recipient: draft.recipient,
            amount: SendDecimalAmount.userUnits(fromAtomicUnits: nativeTransferAmountAtomic,
                                               decimals: draft.asset.decimals), note: draft.note)
            .replacingMaximumBalance(false)
        guard let nativeMaximumInputs else { return adjusted }
        // UTXO sweeps bind the exact reviewed outpoints; new deposits cannot
        // enter the selection. Keep the planner's no-change transaction shape.
        return adjusted.replacingMaximumBalance(true).replacingBitcoinFamilyOptions(
            adjusted.bitcoinFamilyOptions.replacingCoinSelection(.manual(nativeMaximumInputs)))
    }

    func applyingNativeFee(to fee: SendResolvedNetworkFee) -> SendResolvedNetworkFee {
        guard fee.model == .utxoPerVByte, nativeMaximumInputs != nil else { return fee }
        return SendResolvedNetworkFee(model: fee.model, primaryValue: fee.primaryValue,
            secondaryValue: fee.secondaryValue, totalBudgetAtomic: atomicAmount,
            provider: fee.provider, expiresAt: fee.expiresAt, tronParameters: fee.tronParameters)
    }

    func usdValue(unitUSDPrice: Decimal) -> Decimal? {
        guard unitUSDPrice > 0 else { return nil }
        let nativeAmountText = SendDecimalAmount.userUnits(
            fromAtomicUnits: atomicAmount,
            decimals: nativeDecimals
        )
        guard let nativeAmount = Decimal(
            string: nativeAmountText,
            locale: Locale(identifier: "en_US_POSIX")
        ), nativeAmount >= 0 else {
            return nil
        }
        return nativeAmount * unitUSDPrice
    }
}

enum SendNetworkFeeCostBasis: Equatable, Sendable {
    case eip1559(
        units: UInt64,
        minimumRate: UInt64,
        suggestedPriorityRate: String,
        additionalReserve: String = "0"
    )
    case linear(units: UInt64, minimumRate: UInt64, additionalReserve: String = "0")
    case solana(computeUnits: UInt64, baseAtomic: UInt64)
    case direct(minimumAtomic: String)
}

struct SendNetworkFeeEstimator: Sendable {
    typealias BitcoinOutputLoader = @Sendable (
        BitcoinFamilyChain,
        String,
        String?,
        String,
        Set<String>
    ) async throws -> [SendBitcoinUTXO]

    struct SigningContext {
        let walletID: String
        let account: DBWalletAccountRecord
    }

    let database: WalletDatabase
    let bitcoinOutputLoader: BitcoinOutputLoader
    let tronService: SendTronTransactionService

    init(database: WalletDatabase, tronService: SendTronTransactionService = SendTronTransactionService()) {
        self.database = database
        self.tronService = tronService
        let repository = SendBitcoinUTXORepository(database: database)
        bitcoinOutputLoader = {
            chain,
            accountAddress,
            walletID,
            minimumExpectedValueAtomic,
            requiredOutpointIDs in
            try await repository.outputs(
                for: chain,
                accountAddress: accountAddress,
                walletID: walletID,
                minimumExpectedValueAtomic:
                    minimumExpectedValueAtomic,
                requiredOutpointIDs: requiredOutpointIDs
            )
        }
    }

    init(
        database: WalletDatabase,
        bitcoinOutputLoader: @escaping BitcoinOutputLoader
    ) {
        self.database = database
        self.bitcoinOutputLoader = bitcoinOutputLoader
        self.tronService = SendTronTransactionService()
    }

    func estimate(
        draft: SendDraft,
        quote: SendNetworkFeeQuote
    ) async throws -> SendNetworkFeeEstimate {
        let fee = try SendResolvedNetworkFee.resolve(
            policy: draft.feePolicy,
            quote: quote
        )
        return try await estimate(draft: draft, fee: fee)
    }

    func estimate(
        draft: SendDraft,
        fee: SendResolvedNetworkFee
    ) async throws -> SendNetworkFeeEstimate {
        if let totalBudgetAtomic = fee.totalBudgetAtomic,
           fee.model != .utxoPerVByte,
           fee.model != .tronProtocol,
           fee.model != .evmEIP1559, fee.model != .evmLegacy {
            return SendNetworkFeeEstimate(
                atomicAmount: totalBudgetAtomic,
                nativeDecimals: Self.nativeDecimals(for: fee.model)
            )
        }
        let atomicAmount: String
        switch fee.model {
        case .evmEIP1559, .evmLegacy:
            atomicAmount = try await evmFeeAtomic(
                draft: draft,
                fee: fee
            )
        case .utxoPerVByte:
            atomicAmount = try await bitcoinFamilyFeeAtomic(
                draft: draft,
                fee: fee
            )
        case .solanaPriority:
            atomicAmount = try Self.solanaFeeAtomic(
                draft: draft,
                fee: fee
            )
        case .tronProtocol:
            return try await tronService
                .estimatedNetworkFee(
                    draft: draft,
                    fee: fee
                )
        case .tonProtocol, .suiProtocol, .xrpProtocol,
                .aptosProtocol, .nearProtocol, .stellarProtocol:
            atomicAmount = fee.primaryValue
        }
        return SendNetworkFeeEstimate(
            atomicAmount: atomicAmount,
            nativeDecimals: Self.nativeDecimals(for: fee.model)
        )
    }

    /// Checks current spendable outputs and the fee without accessing signing
    /// secrets or broadcasting. A custom total budget still requires a plan.
    func validateBitcoinFunds(draft: SendDraft, fee: SendResolvedNetworkFee) async throws {
        _ = try await bitcoinFamilyFeeAtomic(draft: draft, fee: fee)
    }

    /// Fee choices are visible before Amount is complete. Prefer an exact
    /// transaction estimate, but keep that early screen useful with a
    /// chain-specific transaction template when account, amount, UTXO, or
    /// recipient-dependent preparation is not available yet.
    func estimateForDisplay(
        draft: SendDraft,
        fee: SendResolvedNetworkFee
    ) async throws -> SendNetworkFeeEstimate {
        do {
            return try await estimate(draft: draft, fee: fee)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let estimate = (error as? SendReviewFundingIssue)?.estimate { return estimate }
            if SendBitcoinTransactionPolicy.isSizeError(error) { throw error }
            return try Self.templateEstimate(draft: draft, fee: fee)
        }
    }

    func customCostBasis(
        draft: SendDraft,
        model: SendNetworkFeeCustomModel,
        referenceFee: SendResolvedNetworkFee?,
        minimumFee: SendResolvedNetworkFee?
    ) async throws -> SendNetworkFeeCostBasis {
        do {
            switch model {
            case .evmEIP1559:
                guard let referenceFee,
                      referenceFee.model == model.quoteModel else {
                    return Self.templateCostBasis(
                        draft: draft,
                        model: model,
                        referenceFee: referenceFee,
                        minimumFee: minimumFee
                    )
                }
                return .eip1559(
                    units: try await evmGasLimit(
                        draft: draft,
                        fee: referenceFee
                    ),
                    minimumRate: Self.minimumRate(
                        model: model,
                        fee: minimumFee
                    ),
                    suggestedPriorityRate: Self.priorityRate(
                        from: referenceFee
                    ),
                    additionalReserve: SendEVMRollupFee.defaultReserve(
                        networkID: draft.asset.networkID
                    )
                )
            case .evmLegacy:
                guard let referenceFee,
                      referenceFee.model == model.quoteModel else {
                    return Self.templateCostBasis(
                        draft: draft,
                        model: model,
                        referenceFee: referenceFee,
                        minimumFee: minimumFee
                    )
                }
                return .linear(
                    units: try await evmGasLimit(
                        draft: draft,
                        fee: referenceFee
                    ),
                    minimumRate: Self.minimumRate(
                        model: model,
                        fee: minimumFee
                    ),
                    additionalReserve: SendEVMRollupFee.defaultReserve(
                        networkID: draft.asset.networkID
                    )
                )
            case .utxoPerVByte:
                guard let referenceFee,
                      referenceFee.model == .utxoPerVByte,
                      let rate = UInt64(referenceFee.primaryValue),
                      rate > 0 else {
                    return Self.templateCostBasis(
                        draft: draft,
                        model: model,
                        referenceFee: referenceFee,
                        minimumFee: minimumFee
                    )
                }
                let estimate = try await bitcoinFamilyFeeAtomic(
                    draft: draft,
                    fee: referenceFee
                )
                return .linear(
                    units: try SendAtomicAmount.uint64(
                        SendNetworkFeeCustomLocalConverter.divideCeiling(
                            estimate,
                            by: rate
                        )
                    ),
                    minimumRate: Self.minimumUTXORate(
                        networkID: draft.asset.networkID
                    )
                )
            case .solanaPriority:
                return .solana(
                    computeUnits: draft.asset.isNative
                        ? 200_000 : 400_000,
                    baseAtomic: 5_000
                )
            case .tronFeeLimit:
                if let minimumFee,
                   let estimate = try? await estimateForDisplay(
                       draft: draft,
                       fee: minimumFee
                   ), SendAtomicAmount.isCanonical(
                       estimate.atomicAmount
                   ), estimate.atomicAmount != "0" {
                    return .direct(
                        minimumAtomic: estimate.atomicAmount
                    )
                }
                return Self.templateCostBasis(
                    draft: draft,
                    model: model,
                    referenceFee: referenceFee,
                    minimumFee: minimumFee
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return Self.templateCostBasis(
                draft: draft,
                model: model,
                referenceFee: referenceFee,
                minimumFee: minimumFee
            )
        }
    }

    func localCurrencyValue(
        draft: SendDraft,
        fee: SendResolvedNetworkFee,
        nativeUnitUSDPrice: Decimal?,
        currency: WalletCurrencyContext
    ) async throws -> String? {
        let estimate = try await estimateForDisplay(
            draft: draft,
            fee: fee
        )
        guard let unitPrice = await resolvedNativeUnitUSDPrice(
            networkID: draft.asset.networkID,
            preferredPrice: nativeUnitUSDPrice
        ), let usdValue = estimate.usdValue(unitUSDPrice: unitPrice) else {
            return nil
        }
        return EnglishNumbers.networkFeeCurrency(
            usdValue,
            using: currency
        )
    }

    func resolvedNativeUnitUSDPrice(
        networkID: String,
        preferredPrice: Decimal?
    ) async -> Decimal? {
        if let preferredPrice, preferredPrice > 0 {
            return preferredPrice
        }
        let nativeAssetID = AssetIdentityKey.make(
            networkID: networkID,
            contractAddress: nil
        )
        return (try? await database.cachedAssetUSDPrice(
            assetID: nativeAssetID
        ))?.price
    }

    func availableFeePayerLocalBalance(
        draft: SendDraft,
        model: SendNetworkFeeCustomModel,
        nativeUnitUSDPrice: Decimal?,
        currency: WalletCurrencyContext
    ) async -> Decimal? {
        guard let nativeUnitUSDPrice, nativeUnitUSDPrice > 0,
              currency.ratePerUSD > 0 else { return nil }
        let decimals = Self.nativeDecimals(for: model.quoteModel)
        let atomicBalance: String?

        if draft.asset.isNative {
            if let exact = draft.asset.balanceAtomic,
               SendAtomicAmount.isCanonical(exact) {
                atomicBalance = exact
            } else {
                atomicBalance = try? SendAtomicAmount.fromUserUnits(
                    SendDecimalAmount.decimalStorageText(
                        draft.asset.balance
                    ),
                    decimals: decimals
                )
            }
        } else if let sourceAddress = draft.asset.sourceAddress,
                  let cached = try? await database
                    .cachedNativeFeeBalance(
                        networkID: draft.asset.networkID,
                        sourceAddress: sourceAddress
                    ) {
            if let exact = cached.atomic,
               SendAtomicAmount.isCanonical(exact) {
                atomicBalance = exact
            } else {
                atomicBalance = try? SendAtomicAmount.fromUserUnits(
                    cached.balance,
                    decimals: decimals
                )
            }
        } else {
            atomicBalance = nil
        }

        guard let atomicBalance,
              SendAtomicAmount.isCanonical(atomicBalance),
              let nativeBalance = Decimal(
                  string: SendDecimalAmount.userUnits(
                      fromAtomicUnits: atomicBalance,
                      decimals: decimals
                  ),
                  locale: Locale(identifier: "en_US_POSIX")
              ), nativeBalance >= 0 else { return nil }
        return nativeBalance * nativeUnitUSDPrice * currency.ratePerUSD
    }

    static func nativeDecimals(
        for model: SendNetworkFeeQuoteModel
    ) -> Int {
        switch model {
        case .evmEIP1559, .evmLegacy:
            18
        case .utxoPerVByte:
            8
        case .solanaPriority, .tonProtocol, .suiProtocol:
            9
        case .tronProtocol, .xrpProtocol:
            6
        case .aptosProtocol:
            AptosConstants.decimals
        case .nearProtocol:
            NEARConstants.decimals
        case .stellarProtocol:
            StellarConstants.decimals
        }
    }

    private func evmFeeAtomic(
        draft: SendDraft,
        fee: SendResolvedNetworkFee
    ) async throws -> String {
        let gasLimit = try await evmGasLimit(draft: draft, fee: fee)
        let executionFee = try SendEVMTransactionService.maximumFeeAtomic(
            feePerGas: fee.primaryValue, gasLimit: gasLimit,
            networkID: draft.asset.networkID
        )
        let reserve = try await SendEVMRollupFee.reserve(
            networkID: draft.asset.networkID,
            isToken: !draft.asset.isNative, gasLimit: gasLimit
        )
        let total = SendAtomicAmount.add(executionFee, reserve)
        try SendEVMTransactionService.validateCustomFeeBudget(fee, maximumFeeAtomic: total)
        return total
    }

    private func evmGasLimit(
        draft: SendDraft,
        fee: SendResolvedNetworkFee
    ) async throws -> UInt64 {
        let sourceAddress = draft.asset.sourceAddress?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let recipientAddress = draft.recipient.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let contractAddress = draft.asset.contractAddress?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard SendAddressValidator.isValidEVMAddress(
            recipientAddress
        ) else {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        guard let sourceAddress,
              SendAddressValidator.isValidEVMAddress(sourceAddress) else {
            throw SendTransactionSubmissionError.derivedAddressMismatch
        }
        if let contractAddress,
           !SendAddressValidator.isValidEVMAddress(contractAddress) {
            throw SendTransactionSubmissionError.unsupportedAsset
        }
        if let contractAddress,
           recipientAddress.caseInsensitiveCompare(contractAddress)
            == .orderedSame {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        guard let requestedAmount = draft.amount else {
            throw SendTransactionSubmissionError.invalidAmount
        }
        let rpc = try SendEVMRPCClient(
            networkID: draft.asset.networkID
        )
        if let contractAddress {
            let onChainDecimals = try await rpc.tokenDecimals(
                contractAddress: contractAddress
            )
            guard onChainDecimals == draft.asset.decimals else {
                throw SendTransactionSubmissionError
                    .tokenMetadataMismatch
            }
        }
        let requestedAtomic = try SendAtomicAmount.fromUserUnits(
            requestedAmount,
            decimals: draft.asset.decimals
        )
        let transferData = try SendEVMTransactionService
            .erc20TransferData(
                recipient: recipientAddress,
                amountAtomic: requestedAtomic,
                contractAddress: contractAddress
            )
        let gasLimit: UInt64
        if draft.asset.isNative {
            let balanceHex = try await rpc.nativeBalance(
                address: sourceAddress
            )
            let balance = try SendAtomicAmount.decimalFromHexQuantity(
                balanceHex
            )
            gasLimit = try await SendEVMTransactionService
                .maximumNativeGasLimit(
                    rpc: rpc,
                    nativeBalance: balance,
                    fee: fee,
                    senderAddress: sourceAddress,
                    transactionTarget: recipientAddress,
                    networkID: draft.asset.networkID,
                    requestedAtomic: draft.usesMaximumBalance ? nil : requestedAtomic
                )
        } else {
            let fields = try SendEVMTransactionService
                .gasEstimateFeeFields(fee)
            let gasEstimateHex = try await rpc.estimateGas(
                from: sourceAddress,
                to: contractAddress ?? recipientAddress,
                value: draft.asset.isNative
                    ? try SendAtomicAmount.hexQuantity(requestedAtomic)
                    : "0x0",
                data: transferData,
                gasPrice: fields.gasPrice,
                maximumFeePerGas: fields.maximumFeePerGas,
                priorityFeePerGas: fields.priorityFeePerGas
            )
            let estimatedGas = try SendAtomicAmount.uint64(
                SendAtomicAmount.decimalFromHexQuantity(gasEstimateHex)
            )
            gasLimit = try SendEVMTransactionService.bufferedGasLimit(
                estimatedGas
            )
        }
        return gasLimit
    }

    private func bitcoinFamilyFeeAtomic(
        draft: SendDraft,
        fee: SendResolvedNetworkFee
    ) async throws -> String {
        try await bitcoinFamilyPlan(draft: draft, fee: fee).feeAtomic
    }

    func signingContext(
        for draft: SendDraft
    ) async throws -> SigningContext {
        guard let identity = try await database.selectedWalletIdentity()
        else {
            throw SendTransactionSubmissionError.walletUnavailable
        }
        let accounts = try await WalletDataStore(database: database)
            .accounts(walletID: identity.walletID)
        guard let account = try await SendSigningAccountSelector
            .matchingOwnedAccount(
                in: accounts,
                draft: draft,
                walletID: identity.walletID,
                database: database
            ) else {
            throw SendTransactionSubmissionError.accountUnavailable
        }
        return SigningContext(
            walletID: identity.walletID,
            account: account
        )
    }

    static func solanaFeeAtomic(
        draft: SendDraft,
        fee: SendResolvedNetworkFee
    ) throws -> String {
        let priorityPrice = try SendAtomicAmount.uint64(fee.primaryValue)
        let computeUnitLimit: UInt64 = draft.asset.isNative ? 200_000 : 400_000
        // The intermediate micro-lamport product can exceed UInt64 even when
        // the final lamport amount and the signer's unit price both fit.
        let microLamports = try SendAtomicAmount.multiply(
            String(priorityPrice), by: computeUnitLimit
        )
        let priorityLamports = try SendNetworkFeeCustomLocalConverter.divideCeiling(
            microLamports, by: 1_000_000
        )
        return SendAtomicAmount.add(priorityLamports, "5000")
    }
}

extension EnglishNumbers {
    static func networkFeeCurrency(
        _ usdValue: Decimal,
        using context: WalletCurrencyContext
    ) -> String {
        SendNetworkFeeCurrencyFormatter.shared.string(
            value: usdValue * context.ratePerUSD,
            currencyCode: context.code
        )
    }
}

private final class SendNetworkFeeCurrencyFormatter: @unchecked Sendable {
    static let shared = SendNetworkFeeCurrencyFormatter()

    private let lock = NSLock()
    private var formatters: [String: NumberFormatter] = [:]

    func string(value: Decimal, currencyCode: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        let formatter = formatters[currencyCode] ?? {
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .currency
            formatter.currencyCode = currencyCode
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 8
            formatter.usesGroupingSeparator = true
            formatters[currencyCode] = formatter
            return formatter
        }()
        return formatter.string(from: NSDecimalNumber(decimal: value))
            ?? NSDecimalNumber(decimal: value).stringValue
    }
}

extension SendNetworkFeeCustomModel {
    var quoteModel: SendNetworkFeeQuoteModel {
        switch self {
        case .evmEIP1559: .evmEIP1559
        case .evmLegacy: .evmLegacy
        case .utxoPerVByte: .utxoPerVByte
        case .solanaPriority: .solanaPriority
        case .tronFeeLimit: .tronProtocol
        }
    }
}

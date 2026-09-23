import Foundation
import Observation

/// Review shows its local fee immediately, but only a successful live funding
/// preflight can authorize it. A successful check belongs to this reviewed
/// draft and survives lifecycle changes; editing the draft requires a new check.
@MainActor
@Observable
final class SendReviewFeeState {
    typealias QuoteLoader = @Sendable (String) async throws -> SendNetworkFeeQuote
    typealias EstimateLoader = @Sendable (SendDraft, SendResolvedNetworkFee) async throws -> SendNetworkFeeEstimate
    typealias PriceLoader = @Sendable () async -> Decimal?

    private(set) var fee: SendResolvedNetworkFee?
    private(set) var estimate: SendNetworkFeeEstimate?
    private(set) var usdValue: Decimal?
    // Preserve the concrete preflight failure. The UI and authorization share
    // one gate; no transfer has been submitted while Review is checking funds.
    private(set) var diagnosticError: Error?
    var errorMessage: String? {
        guard !canContinue else { return nil }
        return (blockingEstimateError ?? diagnosticError).map(Self.message)
    }
    private(set) var revision = UUID()
    private var unitUSDPrice: Decimal?
    private var hasCommittedFee = false
    @ObservationIgnored private var reviewedDraft: SendDraft?
    @ObservationIgnored private var activeRequest: UUID?
    private var blockingEstimateError: Error?
    private(set) var hasVerifiedFunds = false
    private(set) var isCheckingFunds = true

    var funding: SendReviewFunding? {
        ((blockingEstimateError ?? diagnosticError) as? SendReviewFundingIssue)?.funding
    }

    var canContinue: Bool {
        guard hasVerifiedFunds, let fee, let estimate, blockingEstimateError == nil else { return false }
        if fee.model == .utxoPerVByte, fee.totalBudgetAtomic != nil {
            // A remembered total is a spending limit, not evidence that the
            // selected inputs fit it. Templates cannot authorize that budget.
            guard case .exact = estimate.source else { return false }
        }
        return true
    }

    init(draft: SendDraft, nativeUnitUSDPrice: Decimal?) {
        unitUSDPrice = nativeUnitUSDPrice
        reset(draft: draft)
    }

    func reset(draft: SendDraft) {
        guard reviewedDraft != draft else { return }
        reviewedDraft = draft
        hasCommittedFee = false
        hasVerifiedFunds = false
        isCheckingFunds = true
        blockingEstimateError = nil
        invalidatePendingUpdates()
        diagnosticError = nil
        do {
            try install(SendSubmissionNetworkFee.resolve(draft: draft), draft: draft)
        } catch {
            fee = nil
            estimate = nil
            usdValue = nil
            diagnosticError = error
        }
    }

    func invalidatePendingUpdates() {
        revision = UUID()
        activeRequest = nil
        // Cancelling a publisher must not discard an already successful check.
    }

    func feeForAuthorization() -> SendResolvedNetworkFee? {
        guard canContinue else { return nil }
        hasCommittedFee = true
        invalidatePendingUpdates()
        return fee.map { estimate?.applyingNativeFee(to: $0) ?? $0 }
    }

    func refresh(
        draft: SendDraft,
        quoteLoader: QuoteLoader,
        estimateLoader: EstimateLoader,
        priceLoader: PriceLoader
    ) async {
        guard !Task.isCancelled else { return }
        if reviewedDraft != draft { reset(draft: draft) }
        guard !canContinue, !hasCommittedFee, activeRequest == nil else { return }
        let request = UUID()
        revision = request
        activeRequest = request
        hasVerifiedFunds = false
        isCheckingFunds = true
        defer {
            if activeRequest == request {
                activeRequest = nil
                isCheckingFunds = false
            }
        }
        diagnosticError = nil
        // A deposit may have changed the balance since the last failure. While
        // rechecking, never recommend another deposit based on stale evidence.
        if blockingEstimateError is SendReviewFundingIssue { blockingEstimateError = nil }

        if draft.feePolicy.requiresLiveQuote || draft.asset.networkID == TronConstants.networkID {
            do {
                let quote = try await quoteLoader(draft.asset.networkID)
                guard accepts(request) else { return }
                let usable = WalletNetworkFeeCachePolicy.canReuse(quote, networkID: draft.asset.networkID)
                    || (quote.provider == SendNetworkFeeAPIClient.builtInDefaultProvider
                        && SendNetworkFeeAPIClient.isValid(quote, expectedNetworkID: draft.asset.networkID))
                guard usable else {
                    throw SendNetworkFeeAPIError.invalidResponse("metadata")
                }
                // This loader reads the durable cache, not the network. Its
                // default means the saved sample is unavailable/expired. Do not
                // resurrect a previously rejected rate on Retry. Committed
                // reviews are protected by the entry guard above.
                let nextFee = try SendResolvedNetworkFee.resolve(policy: draft.feePolicy, quote: quote)
                try install(nextFee, draft: draft)
            } catch is CancellationError {
                return
            } catch {
                guard accepts(request) else { return }
                diagnosticError = error
            }
        }

        guard accepts(request), let fee else { return }
        do {
            let exactEstimate = try await estimateLoader(draft, fee)
            guard accepts(request) else { return }
            blockingEstimateError = nil
            estimate = exactEstimate
            if case .exact = exactEstimate.source { hasVerifiedFunds = true }
            usdValue = unitUSDPrice.flatMap { exactEstimate.usdValue(unitUSDPrice: $0) }
        } catch is CancellationError {
            return
        } catch {
            guard accepts(request) else { return }
            // Preserve the actual rejected cost, never the unrelated template.
            // If preparation failed before calculating a cost, show unavailable.
            estimate = (error as? SendReviewFundingIssue)?.estimate
            usdValue = unitUSDPrice.flatMap { estimate?.usdValue(unitUSDPrice: $0) }
            if Self.blocksAuthorization(error) { blockingEstimateError = error }
            diagnosticError = error
        }

        // Fiat pricing does not determine whether the reviewed fee is ready.
        // End fee loading after preflight, including a definite failure, so a
        // slow optional price request cannot leave a misleading loading control.
        isCheckingFunds = false
        let price = await priceLoader()
        guard accepts(request) else { return }
        if let price, price > 0 { unitUSDPrice = price }
        usdValue = unitUSDPrice.flatMap { estimate?.usdValue(unitUSDPrice: $0) }
    }

    private func accepts(_ request: UUID) -> Bool {
        revision == request && !Task.isCancelled
    }

    private func install(_ nextFee: SendResolvedNetworkFee, draft: SendDraft) throws {
        let nextEstimate = try SendNetworkFeeEstimator.templateEstimate(draft: draft, fee: nextFee)
        fee = nextFee
        estimate = nextEstimate
        usdValue = unitUSDPrice.flatMap { nextEstimate.usdValue(unitUSDPrice: $0) }
    }

    private static func blocksAuthorization(_ error: Error) -> Bool {
        if error is SendReviewFundingIssue { return true }
        if SendBitcoinTransactionPolicy.isSizeError(error) { return true }
        if error is SendBitcoinFamilyOptionsError { return true }
        if let repositoryError = error as? SendBitcoinUTXORepositoryError {
            switch repositoryError {
            case .selectedWalletUnavailable, .accountUnavailable, .invalidAccountAddress, .tooManyOutputs:
                return true
            case .provider, .invalidResponse:
                return false
            }
        }
        guard let submissionError = error as? SendTransactionSubmissionError else { return false }
        switch submissionError {
        case .feeQuoteUnavailable:
            return true
        case .invalidRecipient, .invalidAmount, .amountOutOfRange,
             .derivedAddressMismatch, .tokenMetadataMismatch,
             .insufficientAssetBalance, .insufficientNetworkFeeBalance,
             .unsupportedAsset, .unsupportedNetwork,
             .walletUnavailable, .accountUnavailable, .watchOnlyAccount,
             .secretUnavailable, .selfTransferNotSupported,
             .solanaRecipientRentMinimum, .solanaSenderRentMinimum,
             .spendAlreadyReserved:
            return true
        case let .provider(_, code, message):
            // Clients encode an EVM revert either as RPC code 3 or a server
            // error with a revert reason. Keep the rejection blocking approval.
            return code == "rpc_3"
                || (code.hasPrefix("rpc_") && message.lowercased().contains("revert"))
        default:
            return false
        }
    }

    private static func message(for error: Error) -> String {
        if let issue = error as? SendReviewFundingIssue { return issue.funding.message }
        let providerDetail: String? = switch error {
        case let value as XRPProviderError: value.diagnosticDescription
        case let value as StellarProviderError: value.diagnosticDescription
        case let value as NEARProviderError: value.diagnosticDescription
        case let value as AptosProviderError: value.diagnosticDescription
        case let value as SuiProviderError: value.diagnosticDescription
        case let value as TONProviderError: value.diagnosticDescription
        default: nil
        }
        if let providerDetail { return SendTransactionSubmissionError.sanitizedMessage(providerDetail) }
        if SendBitcoinTransactionPolicy.isSizeError(error) {
            return WalletLocalization.string("send.bitcoin.op_return.error.transaction_too_large")
        }
        if let error = error as? SendNetworkFeeAPIError { return error.localizedMessage }
        if let error = error as? SendTransactionSubmissionError { return error.localizedMessage }
        if let error = error as? SendBitcoinUTXORepositoryError { return error.localizedMessage }
        if let error = error as? SendBitcoinFamilyOptionsError { return error.localizedMessage }
        return EnglishNumbers.localized(
            "send.network_fee.error.unexpected",
            SendTransactionSubmissionError.sanitizedErrorType(error)
        )
    }
}

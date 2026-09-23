import Foundation

/// Read-only affordability preflight. Uses the same native fee budgets and account
/// identities as submission, without loading private keys or signing anything.
struct SendReviewFundsValidator: Sendable {
    let database: WalletDatabase

    func estimate(draft: SendDraft, fee: SendResolvedNetworkFee) async throws -> SendNetworkFeeEstimate {
        let estimator = SendNetworkFeeEstimator(database: database)
        let context = try await estimator.signingContext(for: draft)
        guard let network = ReceiveNetworkCatalog.catalogNetwork(for: draft.asset.networkID) else {
            throw SendTransactionSubmissionError.unsupportedNetwork
        }
        let funding = SendReviewFunding(address: context.account.address, network: network)
        var calculatedEstimate: SendNetworkFeeEstimate?
        do {
            if BitcoinFamilyChain(rawValue: network.id) != nil {
                // Coin selection proves amount + fee affordability for all owned
                // address types, including manually selected inputs and Send Max.
                return try await estimator.nativeBitcoinEstimate(draft: draft, fee: fee)
            }
            if fee.model == .tronProtocol {
                // TRON prepares and validates native/token affordability using
                // one balance/resource snapshot. Keep its net native amount
                // paired with its fee instead of reading a second balance.
                return try await estimator.estimate(draft: draft, fee: fee)
            }
            let state = try await SendReviewNativeBalanceReader(database: database).read(
                draft: draft, fee: fee, account: context.account
            )
            // Reject an empty/insufficient fee payer before a gas simulation can
            // throw an opaque provider error. This floor is not the final budget.
            if network.blockchain.isEVM {
                let floor = try SendAtomicAmount.multiply(fee.primaryValue, by: 21_000)
                try Self.validate(draft: draft, balance: state.balance, cost: floor, reserve: state.reserve)
            }
            let estimate = try await estimator.estimate(draft: draft, fee: fee)
            calculatedEstimate = estimate
            let cost = SendAtomicAmount.add(estimate.atomicAmount, state.additionalCost)
            let nativeAmount = try Self.validate(draft: draft, balance: state.balance, cost: cost, reserve: state.reserve)
            if let rent = state.solanaRentMinimum {
                let debit = SendAtomicAmount.add(cost, nativeAmount ?? "0")
                let remaining = try SendAtomicAmount.subtract(state.balance, debit)
                guard SendSolanaRentPolicy.permitsSenderTransition(
                    preBalance: try SendAtomicAmount.uint64(state.balance),
                    postBalance: try SendAtomicAmount.uint64(remaining), rentMinimum: rent
                ) else { throw SendTransactionSubmissionError.insufficientNetworkFeeBalance }
            }
            return SendNetworkFeeEstimate(atomicAmount: estimate.atomicAmount,
                nativeDecimals: estimate.nativeDecimals, source: estimate.source,
                nativeTransferAmountAtomic: nativeAmount)
        } catch let error as SendTransactionSubmissionError {
            if Self.isFundingFailure(error, draft: draft) {
                throw SendReviewFundingIssue(funding: funding, cause: error, estimate: calculatedEstimate)
            }
            throw error
        }
    }

    @discardableResult
    static func validate(draft: SendDraft, balance: String, cost: String, reserve: String) throws -> String? {
        guard [balance, cost, reserve].allSatisfy(SendAtomicAmount.isCanonical) else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        let unavailable = SendAtomicAmount.add(cost, reserve)
        guard SendAtomicAmount.compare(balance, unavailable) != .orderedAscending else {
            throw SendTransactionSubmissionError.insufficientNetworkFeeBalance
        }
        if draft.asset.isNative {
            return try SendNativeTransferAmountResolver.resolve(
                requestedAtomic: requestedAtomic(draft), balanceAtomic: balance,
                unavailableAtomic: unavailable, usesMaximumBalance: draft.usesMaximumBalance
            )
        }
        return nil
    }

    private static func requestedAtomic(_ draft: SendDraft) throws -> String {
        guard let amount = draft.amount else { throw SendTransactionSubmissionError.invalidAmount }
        return try SendAtomicAmount.fromUserUnits(amount, decimals: draft.asset.decimals)
    }

    private func requestedAtomic(_ draft: SendDraft) throws -> String { try Self.requestedAtomic(draft) }

    static func isFundingFailure(_ error: SendTransactionSubmissionError, draft: SendDraft) -> Bool {
        switch error {
        case .insufficientNetworkFeeBalance: return true
        case .insufficientAssetBalance: return draft.asset.isNative
        case let .provider(network, code, message):
            if network == TronConstants.networkID, network == draft.asset.networkID,
               draft.asset.isNative, code == "provider_error" {
                // A concurrent spend can still invalidate a prepared balance.
                // Preserve the provider error as the funding issue's cause.
                return message.contains("Validate TransferContract error")
                    && message.contains("balance is not sufficient")
            }
            return network == draft.asset.networkID && code.hasPrefix("rpc_")
                && ReceiveNetworkCatalog.catalogNetwork(for: network)?.blockchain.isEVM == true
                && SendTransactionSubmissionError.isNativeFundsRejection(message)
        default: return false
        }
    }
}

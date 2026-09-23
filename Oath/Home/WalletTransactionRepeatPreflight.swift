import Foundation

/// Send Again must prove Bitcoin-family funds are still spendable before it
/// presents Review. Portfolio balances alone can include already-spent inputs.
struct WalletTransactionRepeatPreflight: Sendable {
    typealias FundsValidator = @Sendable (SendDraft) async throws -> Void
    private let validateFunds: FundsValidator

    init(database: WalletDatabase) {
        validateFunds = { draft in
            let preferences = SendNetworkFeePreferenceRepository(database: database)
            let policy = try await preferences.policy(for: draft.asset.networkID)
            let candidate = draft.replacingFeePolicy(policy)
            let fee = try await SendSubmissionNetworkFee.resolve(
                draft: candidate,
                quoteLoader: { try await SendNetworkFeeQuoteRepository.shared.quote(for: $0, database: database) }
            )
            try await SendNetworkFeeEstimator(database: database)
                .validateBitcoinFunds(draft: candidate, fee: fee)
        }
    }

    init(validateFunds: @escaping FundsValidator) {
        self.validateFunds = validateFunds
    }

    func failure(for plan: WalletTransactionRepeatPlan) async -> WalletTransactionRepeatFailure? {
        guard BitcoinFamilyChain(rawValue: plan.draft.asset.networkID) != nil else {
            return nil
        }
        do {
            try Task.checkCancellation()
            try await validateFunds(plan.draft)
            try Task.checkCancellation()
            return nil
        } catch is CancellationError {
            return .presentationUnavailable
        } catch let error as SendTransactionSubmissionError {
            switch error {
            case .insufficientAssetBalance:
                return .insufficientBalance
            case .insufficientNetworkFeeBalance:
                return .insufficientNetworkFeeBalance
            default:
                return .preflightFailed(message: error.localizedMessage)
            }
        } catch let error as SendBitcoinUTXORepositoryError {
            return .preflightFailed(message: error.localizedMessage)
        } catch let error as SendNetworkFeeAPIError {
            return .preflightFailed(message: error.localizedMessage)
        } catch {
            return .preflightFailed(message: SendTransactionSubmissionError.persistence(
                code: SendTransactionSubmissionService.persistenceCode(error)
            ).localizedMessage)
        }
    }
}

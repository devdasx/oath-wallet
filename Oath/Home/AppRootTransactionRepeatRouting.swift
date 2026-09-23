import Foundation

extension AppRootView {
    @MainActor
    func presentRepeatedTransaction(
        _ transaction: WalletTransaction
    ) async -> WalletTransactionRepeatFailure? {
        guard walletActionPresentation == nil else {
            return .presentationUnavailable
        }
        guard let initialContext = authorizedWalletActionContext(
            action: .send
        ) else {
            return .presentationUnavailable
        }
        if preparedWalletActions(for: initialContext) == nil {
            guard await awaitWalletActionReadiness(
                requestID: initialContext.requestID,
                requirement: .presentationSafe
            ) else {
                return .presentationUnavailable
            }
        }
        guard
            walletActionPresentation == nil,
            let context = authorizedWalletActionContext(action: .send)
        else {
            return .presentationUnavailable
        }
        guard let preparation = preparedWalletActions(for: context) else {
            return .presentationUnavailable
        }

        let repeatCandidate: WalletTransaction
        do {
            repeatCandidate = try await
                BitcoinFamilyTransactionIdentityResolver.shared
                .transactionByResolvingRepeatRecipient(transaction)
        } catch {
            return .missingTransactionDetails
        }

        switch WalletTransactionRepeatPreparation.prepare(
            transaction: repeatCandidate,
            walletAssets: balanceResolvedFlowAssets(preparation),
            capabilities: context.capabilities
        ) {
        case let .failure(failure):
            return failure
        case let .success(plan):
            if let failure = await WalletTransactionRepeatPreflight(database: database)
                .failure(for: plan) {
                return failure
            }
            guard !Task.isCancelled,
                  walletActionPresentation == nil,
                  authorizedWalletActionContext(action: .send)?.requestID == context.requestID else {
                return .presentationUnavailable
            }
            presentWalletAction(
                .send(
                    sendPayload(
                        context: context,
                        preparation: preparation,
                        initialRoute: plan.initialRoute
                    )
                ),
                context: context
            )
            enableAssetVisibilityAfterPresenting(plan.walletAsset)
            return nil
        }
    }
}

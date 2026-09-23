import Foundation
import Testing
@testable import Aperture

@MainActor
struct SendReviewFeeStateTests {
    @Test(arguments: SendNetworkFeeAPIClient.supportedQuoteNetworkIDs.sorted())
    func readyReviewSurvivesReopeningWithoutAnotherRequest(networkID: String) async throws {
        let draft = try Self.draft(networkID)
        let state = SendReviewFeeState(draft: draft, nativeUnitUSDPrice: 1)
        let quote = try SendNetworkFeeAPIClient.defaultQuote(for: networkID)
        await state.refresh(draft: draft, quoteLoader: { _ in quote },
                            estimateLoader: Self.template, priceLoader: { 1 })
        let fee = try #require(state.fee)
        let estimate = try #require(state.estimate)
        #expect(state.canContinue)

        for _ in 0..<3 {
            // Backgrounding/covering Review cancels publishers, not its result.
            state.invalidatePendingUpdates()
            state.reset(draft: draft)
            #expect(state.canContinue)
            #expect(!state.isCheckingFunds)
            await state.refresh(draft: draft, quoteLoader: { _ in
                Issue.record("A ready review must not fetch another quote")
                throw SendNetworkFeeAPIError.transport("unexpected_request")
            }, estimateLoader: { _, _ in
                Issue.record("A ready review must not repeat funding preflight")
                throw SendNetworkFeeAPIError.transport("unexpected_request")
            }, priceLoader: {
                Issue.record("Reopening must not restart the completed request")
                return nil
            })
            #expect(state.canContinue)
            #expect(!state.isCheckingFunds)
            #expect(state.fee == fee)
            #expect(state.estimate?.atomicAmount == estimate.atomicAmount)
            #expect(state.estimate?.nativeTransferAmountAtomic == estimate.nativeTransferAmountAtomic)
        }
        #expect(state.feeForAuthorization() != nil)
        state.invalidatePendingUpdates()
        // Returning from a cancelled authorization keeps the reviewed fee.
        #expect(state.canContinue)
        #expect(state.feeForAuthorization() != nil)
    }

    @Test func simultaneousRequestsShareTheInitialCheck() async throws {
        let draft = try Self.draft("bitcoin")
        let state = SendReviewFeeState(draft: draft, nativeUnitUSDPrice: nil)
        let gate = ReviewFeeGate<SendNetworkFeeQuote>()
        let quote = try Self.liveQuote()
        let first = Task {
            await state.refresh(draft: draft, quoteLoader: { _ in try await gate.load() },
                                estimateLoader: Self.template, priceLoader: { nil })
        }
        await gate.waitUntilStarted()
        let revision = state.revision
        await state.refresh(draft: draft, quoteLoader: { _ in
            Issue.record("The in-flight quote must not be requested twice")
            return quote
        }, estimateLoader: { _, _ in
            Issue.record("The duplicate caller must not run another estimator")
            return SendNetworkFeeEstimate(atomicAmount: "1", nativeDecimals: 8)
        }, priceLoader: { nil })
        #expect(state.revision == revision)
        #expect(state.isCheckingFunds)
        #expect(!state.canContinue)
        await gate.succeed(quote)
        await first.value
        #expect(state.canContinue)
        #expect(!state.isCheckingFunds)
    }

    @Test func interruptedInitialCheckCanRestartWithoutPublishingItsOldResult() async throws {
        let draft = try Self.draft("bitcoin")
        let state = SendReviewFeeState(draft: draft, nativeUnitUSDPrice: nil)
        let gate = ReviewFeeGate<SendNetworkFeeQuote>()
        let first = Task {
            await state.refresh(draft: draft, quoteLoader: { _ in try await gate.load() },
                                estimateLoader: Self.template, priceLoader: { nil })
        }
        await gate.waitUntilStarted()
        first.cancel()
        state.invalidatePendingUpdates()
        let fallback = try SendNetworkFeeAPIClient.defaultQuote(for: "bitcoin")
        await state.refresh(draft: draft, quoteLoader: { _ in fallback },
                            estimateLoader: Self.template, priceLoader: { nil })
        let acceptedFee = state.fee
        #expect(state.canContinue)
        await gate.succeed(try Self.liveQuote())
        await first.value
        #expect(state.fee == acceptedFee)
        #expect(state.canContinue)
        #expect(!state.isCheckingFunds)
    }

    @Test func cancellingOptionalPricingKeepsTheSuccessfulFeeReady() async throws {
        let draft = try Self.draft("bitcoin")
        let state = SendReviewFeeState(draft: draft, nativeUnitUSDPrice: nil)
        let quote = try Self.liveQuote()
        let priceGate = ReviewFeeGate<Decimal>()
        let first = Task {
            await state.refresh(draft: draft, quoteLoader: { _ in quote },
                                estimateLoader: Self.template,
                                priceLoader: { try? await priceGate.load() })
        }
        await priceGate.waitUntilStarted()
        #expect(state.canContinue)
        #expect(!state.isCheckingFunds)
        first.cancel()
        state.invalidatePendingUpdates()
        await priceGate.succeed(100)
        await first.value
        #expect(state.canContinue)
        #expect(!state.isCheckingFunds)
        #expect(state.usdValue == nil)
    }

    @Test func changedTransactionRequiresItsOwnCheckAfterAReadyReview() async throws {
        let original = try Self.draft("bitcoin")
        let state = SendReviewFeeState(draft: original, nativeUnitUSDPrice: nil)
        let quote = try Self.liveQuote()
        await state.refresh(draft: original, quoteLoader: { _ in quote },
                            estimateLoader: Self.template, priceLoader: { nil })
        #expect(state.canContinue)
        let changed = original.replacingBitcoinFamilyOptions(
            original.bitcoinFamilyOptions.replacingOPReturnMessage("updated")
        )
        state.reset(draft: changed)
        #expect(!state.canContinue)
        #expect(state.isCheckingFunds)
        await state.refresh(draft: changed, quoteLoader: { _ in quote }, estimateLoader: { draft, fee in
            #expect(draft == changed)
            return try await Self.template(draft, fee)
        }, priceLoader: { nil })
        #expect(state.canContinue)
        #expect(!state.isCheckingFunds)
    }

    @Test(arguments: [false, true])
    func feeLoadingEndsBeforeOptionalFiatPricing(failsPreflight: Bool) async throws {
        let draft = try Self.draft("dogecoin")
        let state = SendReviewFeeState(draft: draft, nativeUnitUSDPrice: nil)
        let quote = try SendNetworkFeeAPIClient.defaultQuote(for: "dogecoin")
        let estimateGate = ReviewFeeGate<SendNetworkFeeEstimate>()
        let priceGate = ReviewFeeGate<Decimal>()
        let refresh = Task {
            await state.refresh(draft: draft, quoteLoader: { _ in quote }, estimateLoader: { _, _ in
                let estimate = try await estimateGate.load()
                if failsPreflight { throw SendNetworkFeeAPIError.transport("estimate_failed") }
                return estimate
            }, priceLoader: { try? await priceGate.load() })
        }
        await estimateGate.waitUntilStarted()
        #expect(state.isCheckingFunds)
        #expect(!state.canContinue)
        await estimateGate.succeed(SendNetworkFeeEstimate(atomicAmount: "1000", nativeDecimals: 8))
        await priceGate.waitUntilStarted()
        #expect(!state.isCheckingFunds)
        #expect(state.canContinue == !failsPreflight)
        #expect((state.errorMessage != nil) == failsPreflight)
        await priceGate.succeed(1)
        await refresh.value
        #expect(!state.isCheckingFunds)
    }

    @Test(arguments: ["1", "2", "3", "17"])
    func automaticBitcoinFeesDoubleTheRecommendationWithFiveSatFloor(rate: String) throws {
        let base = try SendNetworkFeeAPIClient.defaultQuote(for: "bitcoin")
        let quote = SendNetworkFeeQuote(networkID: "bitcoin", provider: "unit-live",
            fetchedAt: Date(), expiresAt: Date().addingTimeInterval(60),
            tiers: base.tiers.map { SendNetworkFeeTier(preset: $0.preset, model: $0.model,
                primaryValue: rate, secondaryValue: nil) })
        for preset in [SendNetworkFeePreset.fastest, .standard, .economy] {
            let fee = try SendResolvedNetworkFee.resolve(policy: .preset(preset), quote: quote)
            #expect(fee.primaryValue == String(max(5, try #require(Int(rate)) * 2)))
            #expect(fee.totalBudgetAtomic == nil)
        }
        let fallback = try SendResolvedNetworkFee.resolve(policy: .preset(.standard), quote: base)
        #expect(fallback.primaryValue == "5")
        let prepared = try Self.draft("bitcoin").replacingPreparedNetworkFee(fallback)
        #expect(try SendSubmissionNetworkFee.resolve(draft: prepared) == fallback)
    }

    @Test
    func bitcoinFeeMarginRejectsOverflowAndDoesNotChangeOtherNetworks() throws {
        #expect(throws: SendTransactionSubmissionError.feeQuoteUnavailable("bitcoin_fee_rate_overflow")) {
            try SendBitcoinTransactionPolicy.automaticFeeRate(String(Int64.max), isBuiltIn: false)
        }
        for network in ["bitcoin_cash", "litecoin", "dogecoin"] {
            let quote = try SendNetworkFeeAPIClient.defaultQuote(for: network)
            let fee = try SendResolvedNetworkFee.resolve(policy: .preset(.standard), quote: quote)
            #expect(fee.primaryValue == quote.tier(for: .standard)?.primaryValue)
        }
    }

    @Test
    func customBitcoinBudgetRequiresAPlanAndCannotBypassFailureOnRetry() async throws {
        let draft = try Self.draft("bitcoin").replacingFeePolicy(.custom(SendNetworkFeeCustomValue(
            model: .utxoPerVByte, primaryValue: "5", secondaryValue: nil, totalBudgetAtomic: "1000"
        )))
        let state = SendReviewFeeState(draft: draft, nativeUnitUSDPrice: 1)
        #expect(!state.canContinue)
        #expect(state.feeForAuthorization() == nil)
        let quoteLoader: SendReviewFeeState.QuoteLoader = { _ in
            Issue.record("A custom fee must not fetch an automatic quote")
            throw SendNetworkFeeAPIError.transport("unexpected_request")
        }
        let gate = ReviewFeeGate<SendNetworkFeeEstimate>()
        let pending = Task {
            await state.refresh(draft: draft, quoteLoader: quoteLoader,
                estimateLoader: { _, _ in try await gate.load() }, priceLoader: { nil })
        }
        await gate.waitUntilStarted()
        #expect(state.feeForAuthorization() == nil)
        await gate.succeed(SendNetworkFeeEstimate(atomicAmount: "1000", nativeDecimals: 8,
            source: .transactionTemplate))
        await pending.value
        #expect(!state.canContinue)
        await state.refresh(draft: draft, quoteLoader: quoteLoader, estimateLoader: { _, _ in
            throw SendTransactionSubmissionError.feeQuoteUnavailable("custom_fee_budget_below_required")
        }, priceLoader: { nil })
        #expect(!state.canContinue)
        #expect(state.errorMessage != nil)
        await state.refresh(draft: draft, quoteLoader: quoteLoader, estimateLoader: { _, _ in
            throw SendNetworkFeeAPIError.transport("offline")
        }, priceLoader: { nil })
        #expect(state.feeForAuthorization() == nil)
        await state.refresh(draft: draft, quoteLoader: quoteLoader, estimateLoader: { _, _ in
            SendNetworkFeeEstimate(atomicAmount: "1000", nativeDecimals: 8)
        }, priceLoader: { nil })
        #expect(state.canContinue)
        #expect(state.feeForAuthorization()?.totalBudgetAtomic == "1000")
    }

    @Test(arguments: SendNetworkFeeAPIClient.supportedQuoteNetworkIDs.sorted())
    func everyMainnetShowsAFeeButWaitsForVerifiedFunds(networkID: String) throws {
        for preset in [SendNetworkFeePreset.fastest, .standard, .economy] {
            let draft = try Self.draft(networkID).replacingFeePolicy(.preset(preset))
            let state = SendReviewFeeState(draft: draft, nativeUnitUSDPrice: 1)
            #expect(!state.canContinue)
            #expect(state.errorMessage == nil)
            #expect(state.fee?.provider == SendNetworkFeeAPIClient.builtInDefaultProvider)
            #expect(state.estimate?.atomicAmount != nil)
            #expect(state.estimate?.atomicAmount != "0")
            #expect(state.usdValue != nil)
        }
    }

    @Test
    func pendingQuoteCannotAuthorizeBeforeBalanceValidation() async throws {
        let draft = try Self.draft("bitcoin")
        let state = SendReviewFeeState(draft: draft, nativeUnitUSDPrice: nil)
        let gate = ReviewFeeGate<SendNetworkFeeQuote>()
        let refresh = Task {
            await state.refresh(draft: draft, quoteLoader: { _ in try await gate.load() },
                                estimateLoader: Self.template, priceLoader: { nil })
        }
        await gate.waitUntilStarted()
        #expect(!state.canContinue)
        #expect(state.feeForAuthorization() == nil)
        await gate.succeed(try Self.liveQuote())
        await refresh.value
        #expect(state.canContinue)
        let selected = try #require(state.feeForAuthorization())
        #expect(selected.primaryValue == "34")
    }

    @Test
    func cachedRateRemainsButUnknownTransactionCostIsNotInvented() async throws {
        let draft = try Self.draft(BitcoinFamilyChain.bitcoin.networkID)
        let state = SendReviewFeeState(draft: draft, nativeUnitUSDPrice: 1)
        let quote = try Self.liveQuote()
        await state.refresh(draft: draft, quoteLoader: { _ in quote }, estimateLoader: { _, _ in
            throw SendNetworkFeeAPIError.transport("estimate_failed")
        }, priceLoader: { 2 })
        #expect(!state.canContinue)
        #expect(state.fee?.primaryValue == "34")
        #expect(state.estimate == nil)
        #expect(state.usdValue == nil)
        #expect(state.feeForAuthorization() == nil)
    }

    @Test(arguments: SendNetworkFeeAPIClient.supportedQuoteNetworkIDs.sorted())
    func failedBalanceReadBlocksEveryMainnet(networkID: String) async throws {
        let draft = try Self.draft(networkID)
        for invalidResponse in [false, true] {
            let state = SendReviewFeeState(draft: draft, nativeUnitUSDPrice: nil)
            let initial = state.fee
            let invalid = try SendNetworkFeeAPIClient.defaultQuote(for: networkID == "eth" ? "bitcoin" : "eth")
            await state.refresh(draft: draft, quoteLoader: { _ in
                if invalidResponse { return invalid }
                throw SendNetworkFeeAPIError.transport("offline")
            }, estimateLoader: { _, _ in throw SendNetworkFeeAPIError.transport("offline") },
               priceLoader: { nil })
            #expect(state.fee == initial)
            #expect(!state.canContinue)
            #expect(state.errorMessage != nil)
            #expect(state.diagnosticError != nil)
        }
    }

    @Test(arguments: BitcoinFamilyChain.allCases)
    func electrumFailureCannotAuthorizeUsingFallbackFee(chain: BitcoinFamilyChain) async throws {
        let draft = try Self.draft(chain.networkID)
        let state = SendReviewFeeState(draft: draft, nativeUnitUSDPrice: 1)
        let quote = try SendNetworkFeeAPIClient.defaultQuote(for: chain.networkID)
        await state.refresh(draft: draft, quoteLoader: { _ in quote }, estimateLoader: { _, _ in
            throw SendBitcoinUTXORepositoryError.provider("rpc_1")
        }, priceLoader: { nil })
        #expect(!state.canContinue)
        #expect(state.errorMessage != nil)
        #expect(state.diagnosticError as? SendBitcoinUTXORepositoryError == .provider("rpc_1"))
        #expect(state.feeForAuthorization() == nil)
    }

    @Test(arguments: SendNetworkFeeAPIClient.supportedQuoteNetworkIDs.sorted())
    func successfulEstimateDoesNotKeepAnEarlierQuoteError(networkID: String) async throws {
        let draft = try Self.draft(networkID)
        let state = SendReviewFeeState(draft: draft, nativeUnitUSDPrice: nil)
        await state.refresh(draft: draft, quoteLoader: { _ in
            throw SendNetworkFeeAPIError.transport("quote_unavailable")
        }, estimateLoader: Self.template, priceLoader: { nil })
        #expect(state.canContinue)
        #expect(state.errorMessage == nil)
        #expect(state.diagnosticError as? SendNetworkFeeAPIError == .transport("quote_unavailable"))
    }

    @Test(arguments: BitcoinFamilyChain.allCases)
    func customBudgetStillShowsProviderFailureWhenExactPlanIsRequired(chain: BitcoinFamilyChain) async throws {
        let draft = try Self.draft(chain.networkID).replacingFeePolicy(.custom(SendNetworkFeeCustomValue(
            model: .utxoPerVByte, primaryValue: "1000", secondaryValue: nil, totalBudgetAtomic: "1000000"
        )))
        let state = SendReviewFeeState(draft: draft, nativeUnitUSDPrice: nil)
        await state.refresh(draft: draft, quoteLoader: { _ in
            Issue.record("Custom budgets must not request automatic quotes")
            throw SendNetworkFeeAPIError.transport("unexpected_request")
        }, estimateLoader: { _, _ in
            throw SendBitcoinUTXORepositoryError.provider("rpc_1")
        }, priceLoader: { nil })
        #expect(!state.canContinue)
        #expect(state.errorMessage == SendBitcoinUTXORepositoryError.provider("rpc_1").localizedMessage)
        #expect(state.feeForAuthorization() == nil)
    }

    @Test
    func retryUsesRepositoryDefaultWhenTheSavedRateIsNoLongerUsable() async throws {
        let draft = try Self.draft("bitcoin")
        let state = SendReviewFeeState(draft: draft, nativeUnitUSDPrice: nil)
        let live = try Self.liveQuote()
        let fallback = try SendNetworkFeeAPIClient.defaultQuote(for: "bitcoin")
        await state.refresh(draft: draft, quoteLoader: { _ in live },
            estimateLoader: { _, _ in throw SendTransactionSubmissionError.insufficientNetworkFeeBalance },
            priceLoader: { nil })
        #expect(state.fee?.primaryValue == "34")
        await state.refresh(draft: draft, quoteLoader: { _ in fallback },
                            estimateLoader: Self.template, priceLoader: { nil })
        #expect(state.fee?.provider == SendNetworkFeeAPIClient.builtInDefaultProvider)
        #expect(state.fee?.primaryValue == (try SendResolvedNetworkFee.resolve(policy: draft.feePolicy, quote: fallback)).primaryValue)
        #expect(state.canContinue)
    }

    @Test(arguments: SendNetworkFeeAPIClient.supportedQuoteNetworkIDs.sorted())
    func insufficientFundsDisplaysCalculatedCostAndNeverAuthorizes(networkID: String) async throws {
        let draft = try Self.draft(networkID)
        let quote = try SendNetworkFeeAPIClient.defaultQuote(for: networkID)
        let network = try #require(ReceiveNetworkCatalog.catalogNetwork(for: networkID))
        let state = SendReviewFeeState(draft: draft, nativeUnitUSDPrice: 2)
        let rejectedCost = SendNetworkFeeEstimate(atomicAmount: "13028500", nativeDecimals: 6)
        await state.refresh(draft: draft, quoteLoader: { _ in quote }, estimateLoader: { _, _ in
            throw SendReviewFundingIssue(funding: .init(address: "owned-account", network: network),
                cause: .insufficientNetworkFeeBalance, estimate: rejectedCost)
        }, priceLoader: { nil })
        #expect(state.estimate?.atomicAmount == "13028500")
        #expect(state.usdValue == Decimal(string: "26.057"))
        #expect(!state.hasVerifiedFunds)
        #expect(!state.canContinue)
        #expect(state.feeForAuthorization() == nil)
        // An offline retry cannot replace the rejected cost with a template or
        // keep recommending a deposit based on an obsolete balance check.
        await state.refresh(draft: draft, quoteLoader: { _ in quote }, estimateLoader: { _, _ in
            throw URLError(.notConnectedToInternet)
        }, priceLoader: { nil })
        #expect(state.estimate == nil)
        #expect(state.usdValue == nil)
        #expect(state.funding == nil)
        #expect(state.feeForAuthorization() == nil)
        await state.refresh(draft: draft, quoteLoader: { _ in quote },
            estimateLoader: { _, _ in rejectedCost }, priceLoader: { nil })
        #expect(state.canContinue)
        #expect(state.errorMessage == nil)
    }

    @Test
    func customSelectionRejectsOlderQuoteAndNeverLoadsAutomaticFee() async throws {
        let draft = try Self.draft(BitcoinFamilyChain.bitcoin.networkID)
        let state = SendReviewFeeState(draft: draft, nativeUnitUSDPrice: nil)
        let gate = ReviewFeeGate<SendNetworkFeeQuote>()
        let refresh = Task {
            await state.refresh(draft: draft, quoteLoader: { _ in try await gate.load() },
                                estimateLoader: Self.template, priceLoader: { nil })
        }
        await gate.waitUntilStarted()
        let custom = draft.replacingFeePolicy(.custom(SendNetworkFeeCustomValue(
            model: .utxoPerVByte, primaryValue: "11", secondaryValue: nil, totalBudgetAtomic: "2000"
        )))
        state.reset(draft: custom)
        await gate.succeed(try Self.liveQuote())
        await refresh.value
        await state.refresh(draft: custom, quoteLoader: { _ in
            Issue.record("Custom must not request an automatic fee")
            throw SendNetworkFeeAPIError.transport("unexpected_request")
        }, estimateLoader: { _, _ in SendNetworkFeeEstimate(atomicAmount: "2000", nativeDecimals: 8) },
           priceLoader: { nil })
        #expect(state.fee?.primaryValue == "11")
        #expect(state.estimate?.atomicAmount == "2000")
        #expect(state.canContinue)
    }

    @Test
    func pendingEstimateCannotAuthorizeAndCommittedFeeRejectsUpdates() async throws {
        let draft = try Self.draft("bitcoin")
        let state = SendReviewFeeState(draft: draft, nativeUnitUSDPrice: nil)
        let quote = try Self.liveQuote()
        let gate = ReviewFeeGate<SendNetworkFeeEstimate>()
        let refresh = Task {
            await state.refresh(draft: draft, quoteLoader: { _ in quote },
                                estimateLoader: { _, _ in try await gate.load() }, priceLoader: { 100 })
        }
        await gate.waitUntilStarted()
        #expect(state.feeForAuthorization() == nil)
        await gate.succeed(SendNetworkFeeEstimate(atomicAmount: "999999", nativeDecimals: 8))
        await refresh.value
        #expect(state.feeForAuthorization()?.primaryValue == "34")
        await state.refresh(draft: draft, quoteLoader: { _ in quote },
            estimateLoader: { _, _ in throw SendTransactionSubmissionError.insufficientNetworkFeeBalance },
            priceLoader: { nil })
        #expect(state.estimate?.atomicAmount == "999999")
    }

    @Test(arguments: ["rpc_3", "rpc_-32000", "rpc_-32015"])
    func contractRevertBlocksFallbackAuthorizationUntilSuccessfulRetry(code: String) async throws {
        let draft = try Self.draft("eth")
        let state = SendReviewFeeState(draft: draft, nativeUnitUSDPrice: 1)
        let quote = try SendNetworkFeeAPIClient.defaultQuote(for: "eth")
        let rejection = SendTransactionSubmissionError.provider(networkID: "eth", code: code,
            message: "execution reverted: TransferHelper: TRANSFER_FROM_FAILED")
        await state.refresh(draft: draft, quoteLoader: { _ in quote }, estimateLoader: { _, _ in
            throw rejection
        }, priceLoader: { nil })
        #expect(!state.canContinue)
        #expect(state.feeForAuthorization() == nil)
        #expect(state.estimate == nil)
        #expect(state.diagnosticError as? SendTransactionSubmissionError == rejection)
        #expect(state.errorMessage == rejection.localizedMessage)
        let rejectionMessage = state.errorMessage

        // A retry may load another quote, then fail to reach the node. It must
        // not silently treat the earlier rejected transaction as sendable.
        await state.refresh(draft: draft, quoteLoader: { _ in quote }, estimateLoader: { _, _ in
            throw SendNetworkFeeAPIError.transport("offline")
        }, priceLoader: { nil })
        #expect(!state.canContinue)
        #expect(state.feeForAuthorization() == nil)
        #expect(state.errorMessage == rejectionMessage)
        #expect(state.diagnosticError as? SendNetworkFeeAPIError == .transport("offline"))

        await state.refresh(draft: draft, quoteLoader: { _ in quote },
                            estimateLoader: Self.template, priceLoader: { nil })
        #expect(state.canContinue)
        #expect(state.errorMessage == nil)
        #expect(state.feeForAuthorization() != nil)
    }

    @Test(arguments: SendNetworkFeeAPIClient.supportedQuoteNetworkIDs.sorted())
    func validationFailureCannotAuthorizeUsingTemplateFee(networkID: String) async throws {
        let draft = try Self.draft(networkID)
        let quote = try SendNetworkFeeAPIClient.defaultQuote(for: networkID)
        for error in [SendTransactionSubmissionError.insufficientAssetBalance,
                      .insufficientNetworkFeeBalance, .tokenMetadataMismatch] {
            let state = SendReviewFeeState(draft: draft, nativeUnitUSDPrice: nil)
            await state.refresh(draft: draft, quoteLoader: { _ in quote }, estimateLoader: { _, _ in
                throw error
            }, priceLoader: { nil })
            #expect(!state.canContinue)
            #expect(state.feeForAuthorization() == nil)
            #expect(state.errorMessage == error.localizedMessage)
        }
    }

    @Test(arguments: [SendBitcoinUTXORepositoryError.selectedWalletUnavailable,
                      .accountUnavailable, .invalidAccountAddress, .tooManyOutputs])
    func unavailableUTXOAccountCannotUseFallback(error: SendBitcoinUTXORepositoryError) async throws {
        let draft = try Self.draft("dogecoin")
        let quote = try SendNetworkFeeAPIClient.defaultQuote(for: "dogecoin")
        let state = SendReviewFeeState(draft: draft, nativeUnitUSDPrice: nil)
        await state.refresh(draft: draft, quoteLoader: { _ in quote }, estimateLoader: { _, _ in
            throw error
        }, priceLoader: { nil })
        #expect(!state.canContinue)
        #expect(state.errorMessage == error.localizedMessage)
        #expect(state.feeForAuthorization() == nil)
    }

    @Test(arguments: SendNetworkFeeAPIClient.supportedQuoteNetworkIDs.sorted())
    func nativeFundingIncludesAmountFeeAndRequiredReserve(networkID: String) throws {
        let draft = try Self.draft(networkID)
        let amount = try SendAtomicAmount.fromUserUnits("0.01", decimals: draft.asset.decimals)
        let exact = SendAtomicAmount.add(amount, "150")
        try SendReviewFundsValidator.validate(draft: draft, balance: exact, cost: "100", reserve: "50")
        #expect(try SendReviewFundsValidator.validate(draft: draft,
            balance: SendAtomicAmount.subtract(exact, "1"), cost: "100", reserve: "50")
            == SendAtomicAmount.subtract(amount, "1"))
        #expect(throws: SendTransactionSubmissionError.insufficientNetworkFeeBalance) {
            try SendReviewFundsValidator.validate(draft: draft, balance: "99", cost: "100", reserve: "0")
        }
    }

    @Test(arguments: ["arbitrum", "scroll", "base", "solana", "tron", "ton", "sui", "xrp", "near", "aptos", "stellar"])
    func fundingFailureBlocksThenSuccessfulRetryClearsDeposit(networkID: String) async throws {
        let draft = try Self.draft(networkID)
        let network = try #require(ReceiveNetworkCatalog.catalogNetwork(for: networkID))
        let funding = SendReviewFunding(address: "owned-account", network: network)
        let state = SendReviewFeeState(draft: draft, nativeUnitUSDPrice: nil)
        let quote = try SendNetworkFeeAPIClient.defaultQuote(for: networkID)
        await state.refresh(draft: draft, quoteLoader: { _ in quote }, estimateLoader: { _, _ in
            throw SendReviewFundingIssue(funding: funding, cause: .insufficientNetworkFeeBalance)
        }, priceLoader: { nil })
        #expect(!state.canContinue)
        #expect(state.feeForAuthorization() == nil)
        #expect(state.funding?.address == "owned-account")
        #expect(state.funding?.network.id == networkID)
        #expect(state.errorMessage == funding.message)
        await state.refresh(draft: draft, quoteLoader: { _ in quote }, estimateLoader: { _, _ in
            throw SendNetworkFeeAPIError.transport("offline")
        }, priceLoader: { nil })
        #expect(!state.canContinue)
        #expect(state.funding == nil)
        #expect(state.diagnosticError as? SendNetworkFeeAPIError == .transport("offline"))
        await state.refresh(draft: draft, quoteLoader: { _ in quote }, estimateLoader: Self.template,
                            priceLoader: { nil })
        #expect(state.canContinue)
        #expect(state.funding == nil)
        #expect(state.errorMessage == nil)
    }

    @Test(arguments: SendNetworkFeeAPIClient.supportedQuoteNetworkIDs.sorted())
    func nativeMaxDeductsFeeAndReserveWithoutRounding(networkID: String) throws {
        let draft = try Self.draft(networkID).replacingMaximumBalance(true)
        // Above Double's exact integer range; fees and reserves must remain exact.
        #expect(try SendReviewFundsValidator.validate(draft: draft,
            balance: "9007199254740993", cost: "100", reserve: "50") == "9007199254740843")
        #expect(try SendReviewFundsValidator.validate(draft: draft,
            balance: "151", cost: "100", reserve: "50") == "1")
        #expect(throws: SendTransactionSubmissionError.insufficientNetworkFeeBalance) {
            try SendReviewFundsValidator.validate(draft: draft, balance: "150", cost: "100", reserve: "50")
        }
    }

    @Test
    func scrollNodeAffordabilityErrorIsFundingButRevertIsNot() throws {
        let draft = try Self.draft("scroll")
        #expect(SendReviewFundsValidator.isFundingFailure(.provider(networkID: "scroll", code: "rpc_-32000",
            message: "insufficient funds for transfer"), draft: draft))
        #expect(SendReviewFundsValidator.isFundingFailure(.provider(networkID: "scroll", code: "rpc_-32000",
            message: "err: insufficient funds for gas * price + value: address 0x1 have 0 want 1 (supplied gas 10000734)"), draft: draft))
        #expect(!SendReviewFundsValidator.isFundingFailure(.provider(networkID: "scroll", code: "rpc_-32000",
            message: "execution reverted: insufficient funds"), draft: draft))
        #expect(!SendReviewFundsValidator.isFundingFailure(.broadcastOutcomeUnknown(networkID: "scroll", code: "timeout"), draft: draft))
    }

    @Test(arguments: SendNetworkFeeAPIClient.supportedQuoteNetworkIDs.sorted().filter { BitcoinFamilyChain(rawValue: $0) == nil })
    func tokenFundingNeedsNativeCostsRatherThanTheTokenAmount(networkID: String) throws {
        let draft = try Self.draft(networkID, token: true).replacingMaximumBalance(true)
        // The token quantity can be much larger than the native fee balance.
        #expect(try SendReviewFundsValidator.validate(draft: draft, balance: "150", cost: "100", reserve: "50") == nil)
        #expect(throws: SendTransactionSubmissionError.insufficientNetworkFeeBalance) {
            try SendReviewFundsValidator.validate(draft: draft, balance: "149", cost: "100", reserve: "50")
        }
        #expect(!SendReviewFundsValidator.isFundingFailure(.insufficientAssetBalance, draft: draft))
    }

    @Test(arguments: SendNetworkFeeAPIClient.supportedQuoteNetworkIDs.sorted())
    func reviewCommitsTheDisplayedNetNativeAmount(networkID: String) async throws {
        let draft = try Self.draft(networkID).replacingMaximumBalance(true)
        let state = SendReviewFeeState(draft: draft, nativeUnitUSDPrice: nil)
        let quote = try SendNetworkFeeAPIClient.defaultQuote(for: networkID)
        await state.refresh(draft: draft, quoteLoader: { _ in quote }, estimateLoader: { draft, _ in
            SendNetworkFeeEstimate(atomicAmount: "100", nativeDecimals: draft.asset.decimals,
                                   nativeTransferAmountAtomic: "800")
        }, priceLoader: { nil })
        #expect(state.canContinue)
        let reviewed = try #require(state.estimate).applyingNativeAmount(to: draft)
        #expect(try SendAtomicAmount.fromUserUnits(#require(reviewed.amount), decimals: draft.asset.decimals) == "800")
        #expect(!reviewed.usesMaximumBalance)
        #expect(state.feeForAuthorization() != nil)
    }

    nonisolated private static func template(_ draft: SendDraft, _ fee: SendResolvedNetworkFee) async throws -> SendNetworkFeeEstimate {
        let value = try SendNetworkFeeEstimator.templateEstimate(draft: draft, fee: fee)
        return SendNetworkFeeEstimate(atomicAmount: value.atomicAmount, nativeDecimals: value.nativeDecimals)
    }

    private static func liveQuote() throws -> SendNetworkFeeQuote {
        let baseline = try SendNetworkFeeAPIClient.defaultQuote(for: BitcoinFamilyChain.bitcoin.networkID)
        return SendNetworkFeeQuote(networkID: BitcoinFamilyChain.bitcoin.networkID, provider: "unit-live", fetchedAt: Date(),
                                   expiresAt: Date().addingTimeInterval(60), tiers: baseline.tiers.map {
            SendNetworkFeeTier(preset: $0.preset, model: $0.model, primaryValue: "17", secondaryValue: nil)
        })
    }
    private static func draft(
        _ networkID: String, token: Bool = false
    ) throws -> SendDraft {
        let network = ReceiveNetworkCatalog.all.first {
            $0.id == networkID
        }
        let bitcoinFamily = BitcoinFamilyChain(rawValue: networkID)
        let blockchain = try #require(
            network?.blockchain ?? bitcoinFamily?.blockchain
        )
        let quote = try SendNetworkFeeAPIClient.defaultQuote(
            for: networkID
        )
        let model = try #require(
            quote.tier(for: .fastest)?.model
        )
        return SendDraft(
            request: .manualEntry(networkID: networkID),
            asset: SendAssetChoice(
                id: "\(networkID):native",
                name: network?.localizedName
                    ?? bitcoinFamily?.name
                    ?? "Native Asset",
                symbol: network?.symbol
                    ?? bitcoinFamily?.symbol
                    ?? "COIN",
                networkID: networkID,
                networkName: network?.localizedName
                    ?? bitcoinFamily?.name
                    ?? "Mainnet",
                blockchain: blockchain,
                contractAddress: token ? "token-contract" : nil,
                decimals: SendNetworkFeeEstimator.nativeDecimals(
                    for: model
                ),
                logoSource: .nativeCoin(blockchain: blockchain),
                networkLogoSource: .network(blockchain: blockchain),
                balance: 1,
                fiatValue: 1,
                sourceAddress: bitcoinFamily == nil
                    ? nil : "source"
            ),
            recipient: bitcoinFamily == nil ? "recipient" : "destination",
            amount: "0.01",
            note: nil
        )
    }

}

private actor ReviewFeeGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func load() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func succeed(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

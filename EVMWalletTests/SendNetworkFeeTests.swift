import Foundation
import Testing
@testable import Aperture

struct SendNetworkFeeTests {
    @Test
    func evmBroadcastClassifierKeepsServerFailuresAmbiguous() {
        #expect(!SendEVMSubmissionErrorClassifier.isDefinitiveRPCRejection(
            code: -32_000,
            message: "nonce too low"
        ))
        #expect(SendEVMSubmissionErrorClassifier.isDefinitiveRPCRejection(
            code: -32_602,
            message: "invalid params"
        ))
        #expect(!SendEVMSubmissionErrorClassifier.isDefinitiveRPCRejection(
            code: -32_603,
            message: "internal error"
        ))
        #expect(!SendEVMSubmissionErrorClassifier.isDefinitiveRPCRejection(
            code: -32_005,
            message: "rate limited"
        ))
    }

    @Test
    func baseUnitConversionIsLosslessAndRejectsInvalidInput() throws {
        #expect(
            try SendNetworkFeeBaseUnitConverter.baseUnits(
                from: "42.000000001",
                decimals: 9,
                permitsZero: false
            ) == "42000000001"
        )
        #expect(
            try SendNetworkFeeBaseUnitConverter.baseUnits(
                from: "0",
                decimals: 6,
                permitsZero: true
            ) == "0"
        )
        #expect(throws: SendPaymentRequestError.invalidAmount) {
            try SendNetworkFeeBaseUnitConverter.baseUnits(
                from: "1.0000000001",
                decimals: 9,
                permitsZero: false
            )
        }
        #expect(throws: SendNetworkFeeInputError.zero) {
            try SendNetworkFeeBaseUnitConverter.baseUnits(
                from: "0",
                decimals: 9,
                permitsZero: false
            )
        }
    }

    @Test
    func customFeeValidationMatchesEachChainFamily() {
        let evm = SendNetworkFeeCustomValue(
            model: .evmEIP1559,
            primaryValue: "42000000000",
            secondaryValue: "2000000000",
            totalBudgetAtomic: "882000000000000"
        )
        #expect(evm.isValid(for: "eth"))
        #expect(!evm.isValid(for: "bitcoin"))

        let invalidEVM = SendNetworkFeeCustomValue(
            model: .evmEIP1559,
            primaryValue: "1000000000",
            secondaryValue: "2000000000",
            totalBudgetAtomic: "21000000000000"
        )
        #expect(!invalidEVM.isValid(for: "eth"))

        let legacyEVM = SendNetworkFeeCustomValue(
            model: .evmLegacy,
            primaryValue: "42000000000",
            secondaryValue: nil,
            totalBudgetAtomic: "882000000000000"
        )
        #expect(legacyEVM.isValid(for: "eth"))

        let bitcoin = SendNetworkFeeCustomValue(
            model: .utxoPerVByte,
            primaryValue: "23",
            secondaryValue: nil,
            totalBudgetAtomic: "5198"
        )
        #expect(bitcoin.isValid(for: "bitcoin"))

        let solana = SendNetworkFeeCustomValue(
            model: .solanaPriority,
            primaryValue: "0",
            secondaryValue: nil,
            totalBudgetAtomic: "5000"
        )
        #expect(solana.isValid(for: "solana"))

        let tron = SendNetworkFeeCustomValue(
            model: .tronFeeLimit,
            primaryValue: "30000000",
            secondaryValue: nil,
            totalBudgetAtomic: "30000000"
        )
        #expect(tron.isValid(for: "tron"))

        let unrecoverableLegacyRate = SendNetworkFeeCustomValue(
            model: .utxoPerVByte,
            primaryValue: "23",
            secondaryValue: nil
        )
        #expect(!unrecoverableLegacyRate.isValid(for: "bitcoin"))
    }

    @Test
    func everyCustomFeeModelBypassesAutomaticQuoteLoading() async throws {
        let cases: [(
            networkID: String,
            blockchain: WalletBlockchain,
            value: SendNetworkFeeCustomValue,
            resolvedModel: SendNetworkFeeQuoteModel
        )] = [
            (
                "eth",
                .ethereum,
                SendNetworkFeeCustomValue(
                    model: .evmEIP1559,
                    primaryValue: "42000000000",
                    secondaryValue: "2000000000",
                    totalBudgetAtomic: "882000000000000"
                ),
                .evmEIP1559
            ),
            (
                "eth",
                .ethereum,
                SendNetworkFeeCustomValue(
                    model: .evmLegacy,
                    primaryValue: "42000000000",
                    secondaryValue: nil,
                    totalBudgetAtomic: "882000000000000"
                ),
                .evmLegacy
            ),
            (
                "bitcoin",
                .bitcoin,
                SendNetworkFeeCustomValue(
                    model: .utxoPerVByte,
                    primaryValue: "23",
                    secondaryValue: nil,
                    totalBudgetAtomic: "5198"
                ),
                .utxoPerVByte
            ),
            (
                SolanaConstants.networkID,
                .solana,
                SendNetworkFeeCustomValue(
                    model: .solanaPriority,
                    primaryValue: "1000",
                    secondaryValue: nil,
                    totalBudgetAtomic: "5200"
                ),
                .solanaPriority
            ),
            (
                TronConstants.networkID,
                .tron,
                SendNetworkFeeCustomValue(
                    model: .tronFeeLimit,
                    primaryValue: "30000000",
                    secondaryValue: nil,
                    totalBudgetAtomic: "30000000"
                ),
                .tronProtocol
            )
        ]

        for item in cases {
            let policy = SendNetworkFeePolicy.custom(item.value)
            #expect(!policy.requiresLiveQuote)
            let draft = Self.customFeeDraft(
                networkID: item.networkID,
                blockchain: item.blockchain,
                policy: policy
            )
            let resolved = try await SendSubmissionNetworkFee.resolve(
                draft: draft,
                quoteLoader: { _ in
                    throw SendNetworkFeeAPIError.transport(
                        "provider_must_not_be_called"
                    )
                }
            )

            #expect(resolved.model == item.resolvedModel)
            #expect(resolved.primaryValue == item.value.primaryValue)
            #expect(resolved.secondaryValue == item.value.secondaryValue)
            #expect(
                resolved.totalBudgetAtomic
                    == item.value.totalBudgetAtomic
            )
        }
    }

    @Test
    func customFeeOverridesAStalePreparedAutomaticFee() async throws {
        let custom = SendNetworkFeeCustomValue(
            model: .utxoPerVByte,
            primaryValue: "4",
            secondaryValue: nil,
            totalBudgetAtomic: "1000"
        )
        let stalePrepared = SendResolvedNetworkFee(
            model: .utxoPerVByte,
            primaryValue: "99",
            secondaryValue: nil
        )
        let draft = Self.bitcoinDraft(
            preparedNetworkFee: stalePrepared
        ).replacingFeePolicy(.custom(custom))

        let resolved = try await SendSubmissionNetworkFee.resolve(
            draft: draft,
            quoteLoader: { _ in
                throw SendNetworkFeeAPIError.transport(
                    "provider_must_not_be_called"
                )
            }
        )

        #expect(resolved.primaryValue == "4")
        #expect(resolved.totalBudgetAtomic == "1000")
    }

    @Test
    func networkFeeCurrencyUsesSelectedCurrencyAndASCIIDigits() throws {
        let value = try #require(
            Decimal(
                string: "0.000001",
                locale: Locale(identifier: "en_US_POSIX")
            )
        )
        let context = WalletCurrencyContext(
            code: "AED",
            ratePerUSD: try #require(
                Decimal(
                    string: "3.6725",
                    locale: Locale(identifier: "en_US_POSIX")
                )
            )
        )

        let formatted = EnglishNumbers.networkFeeCurrency(
            value,
            using: context
        )

        #expect(formatted.contains("AED"))
        #expect(formatted.contains("0.00000367"))
        #expect(formatted.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.decimalDigits.contains(scalar)
                || (scalar.value >= 48 && scalar.value <= 57)
        })
    }

    @Test
    func reviewFeeUsesEveryNetworksNativePrecisionForFiatValue() {
        let expected: [(SendNetworkFeeQuoteModel, Int)] = [
            (.evmEIP1559, 18),
            (.evmLegacy, 18),
            (.utxoPerVByte, 8),
            (.solanaPriority, 9),
            (.tronProtocol, 6),
            (.tonProtocol, 9),
            (.suiProtocol, 9),
            (.xrpProtocol, 6),
            (.aptosProtocol, AptosConstants.decimals),
            (.nearProtocol, NEARConstants.decimals),
            (.stellarProtocol, StellarConstants.decimals)
        ]

        for (model, decimals) in expected {
            #expect(
                SendNetworkFeeEstimator.nativeDecimals(
                    for: model
                ) == decimals
            )
            let oneNativeCoin = "1" + String(
                repeating: "0",
                count: decimals
            )
            let estimate = SendNetworkFeeEstimate(
                atomicAmount: oneNativeCoin,
                nativeDecimals: decimals
            )
            #expect(estimate.usdValue(unitUSDPrice: 2.5) == 2.5)
        }
    }

    @Test
    func everySupportedMainnetHasExactlyOneFeeQuoteRoute() {
        let catalogNetworkIDs = Set(
            ReceiveNetworkCatalog.all.map(\.id)
        ).union(
            BitcoinFamilyChain.allCases.map(\.networkID)
        )

        #expect(catalogNetworkIDs.count == 26)
        #expect(
            SendNetworkFeeAPIClient.supportedQuoteNetworkIDs
                == catalogNetworkIDs
        )
        #expect(
            SendNetworkFeeAPIClient.directQuoteNetworkIDs
                .isDisjoint(
                    with: SendNetworkFeeAPIClient.workerQuoteNetworkIDs
                )
        )
    }

    @Test
    func everySupportedMainnetHasAValidBuiltInDefaultFee() throws {
        let expected: [
            String: (
                model: SendNetworkFeeQuoteModel,
                primary: String,
                secondary: String?
            )
        ] = [
            "eth": (.evmEIP1559, "30000000000", "2000000000"),
            "bsc": (.evmEIP1559, "3000000000", "100000000"),
            "arbitrum": (.evmEIP1559, "200000000", "10000000"),
            "base": (.evmEIP1559, "200000000", "20000000"),
            "polygon": (
                .evmEIP1559,
                "1000000000000",
                "350000000000"
            ),
            "optimism": (.evmEIP1559, "20000000", "1000000"),
            "avalanche": (
                .evmEIP1559,
                "2000000000",
                "1000000000"
            ),
            "gnosis": (.evmEIP1559, "1000000", "1000"),
            "linea": (.evmEIP1559, "200000000", "100000000"),
            "scroll": (.evmEIP1559, "20000000", "1000000"),
            "taiko": (.evmEIP1559, "200000000", "10000000"),
            "telos": (
                .evmEIP1559,
                "6000000000000",
                "5500000000000"
            ),
            "xlayer": (.evmEIP1559, "200000000", "10000000"),
            "arc": (.evmEIP1559, "40000000000", "1000000000"),
            "bitcoin": (.utxoPerVByte, "5", nil),
            "bitcoin_cash": (.utxoPerVByte, "1", nil),
            "litecoin": (.utxoPerVByte, "2", nil),
            "dogecoin": (.utxoPerVByte, "1000", nil),
            SolanaConstants.networkID: (.solanaPriority, "0", nil),
            TronConstants.networkID: (.tronProtocol, "100", "1000"),
            TONConstants.networkID: (
                .tonProtocol,
                "50000000",
                "100000000"
            ),
            SuiConstants.networkID: (.suiProtocol, "10000000", "1000"),
            XRPConstants.networkID: (.xrpProtocol, "10", nil),
            NEARConstants.networkID: (
                .nearProtocol,
                "10000000000000000000000",
                "100000000"
            ),
            AptosConstants.networkID: (
                .aptosProtocol,
                "2000000",
                "100"
            ),
            StellarConstants.networkID: (.stellarProtocol, "100", nil)
        ]
        #expect(Set(expected.keys) == SendNetworkFeeAPIClient
            .supportedQuoteNetworkIDs)

        for (networkID, values) in expected {
            let quote = try SendNetworkFeeAPIClient.defaultQuote(
                for: networkID
            )
            #expect(
                quote.provider
                    == SendNetworkFeeAPIClient.builtInDefaultProvider
            )
            #expect(
                SendNetworkFeeAPIClient.isValid(
                    quote,
                    expectedNetworkID: networkID
                ),
                "Built-in fee validation rejected \(networkID)."
            )
            for preset in [
                SendNetworkFeePreset.fastest,
                .standard,
                .economy
            ] {
                let tier = try #require(quote.tier(for: preset))
                #expect(tier.model == values.model)
                #expect(tier.primaryValue == values.primary)
                #expect(tier.secondaryValue == values.secondary)
            }
        }
    }

    @Test
    func submissionUsesPreparedFeeWithoutCallingTheProvider() async throws {
        let prepared = SendResolvedNetworkFee(
            model: .utxoPerVByte,
            primaryValue: "17",
            secondaryValue: nil,
            provider: "mempool.space",
            expiresAt: Date().addingTimeInterval(60)
        )
        let draft = Self.bitcoinDraft(preparedNetworkFee: prepared)

        let resolved = try await SendSubmissionNetworkFee.resolve(
            draft: draft,
            quoteLoader: { _ in
                throw SendNetworkFeeAPIError.transport(
                    "provider_must_not_be_called"
                )
            }
        )

        #expect(resolved == prepared)
    }

    @Test
    func submissionKeepsReviewedFeeAfterProviderTTLExpires() async throws {
        let expired = SendResolvedNetworkFee(
            model: .utxoPerVByte,
            primaryValue: "17",
            secondaryValue: nil,
            provider: "mempool.space",
            expiresAt: Date().addingTimeInterval(-1)
        )
        let draft = Self.bitcoinDraft(preparedNetworkFee: expired)

        let synchronousResolved = try SendSubmissionNetworkFee.resolve(
            draft: draft
        )
        let asynchronousResolved = try await SendSubmissionNetworkFee.resolve(
            draft: draft,
            quoteLoader: { _ in
                throw SendNetworkFeeAPIError.transport(
                    "provider_must_not_be_called"
                )
            }
        )

        #expect(synchronousResolved == expired)
        #expect(asynchronousResolved == expired)
    }

    @Test
    func everyMainnetUsesBuiltInFeeWhenLiveProviderFails() async throws {
        for networkID in SendNetworkFeeAPIClient
            .supportedQuoteNetworkIDs.sorted() {
            let quote = try await SendNetworkFeeAPIClient.quoteWithFallback(
                for: networkID,
                timeout: .seconds(1)
            ) {
                throw SendNetworkFeeAPIError.server(
                    status: 503,
                    code: "providers_unavailable"
                )
            }

            #expect(
                quote.provider
                    == SendNetworkFeeAPIClient.builtInDefaultProvider,
                "Expected built-in fee for \(networkID)."
            )
            #expect(
                SendNetworkFeeAPIClient.isValid(
                    quote,
                    expectedNetworkID: networkID
                ),
                "Invalid built-in fee for \(networkID)."
            )
        }
    }

    @Test
    func submissionWithoutReviewStillUsesImmediateBuiltInFee() throws {
        let resolved = try SendSubmissionNetworkFee.resolve(
            draft: Self.bitcoinDraft(preparedNetworkFee: nil)
        )

        #expect(resolved.model == .utxoPerVByte)
        #expect(resolved.primaryValue == "5")
        #expect(resolved.secondaryValue == nil)
    }

    @Test
    func feeFailureReturnsBuiltInDefaultInsteadOfBlockingSend() async throws {
        let quote = try await SendNetworkFeeAPIClient.quoteWithFallback(
            for: "bitcoin",
            timeout: .seconds(1)
        ) {
            throw SendNetworkFeeAPIError.server(
                status: 503,
                code: "providers_unavailable"
            )
        }

        #expect(
            quote.provider
                == SendNetworkFeeAPIClient.builtInDefaultProvider
        )
        #expect(quote.tier(for: .fastest)?.primaryValue == "5")
    }

    @Test
    func feeDeadlineCancelsLateProviderAndReturnsDefault() async throws {
        let probe = SendNetworkFeeTimeoutProbe()
        let clock = ContinuousClock()
        let started = clock.now

        let quote = try await SendNetworkFeeAPIClient.quoteWithFallback(
            for: "bitcoin",
            timeout: .milliseconds(20)
        ) {
            await probe.markStarted()
            do {
                try await Task.sleep(for: .seconds(30))
                return try SendNetworkFeeAPIClient.defaultQuote(
                    for: "bitcoin"
                )
            } catch {
                await probe.markCancelled()
                throw error
            }
        }

        #expect(started.duration(to: clock.now) < .seconds(1))
        #expect(await probe.didStart())
        #expect(await probe.wasCancelled())
        #expect(
            quote.provider
                == SendNetworkFeeAPIClient.builtInDefaultProvider
        )
        #expect(quote.tier(for: .fastest)?.primaryValue == "5")
    }

    @Test
    func callerCancellationDoesNotTurnIntoAFallbackQuote() async throws {
        let task = Task {
            try await SendNetworkFeeAPIClient.quoteWithFallback(
                for: "bitcoin",
                timeout: .seconds(30)
            ) {
                try await Task.sleep(for: .seconds(30))
                return try SendNetworkFeeAPIClient.defaultQuote(
                    for: "bitcoin"
                )
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test
    func quoteValidationEnforcesEveryNetworksFeeModelAndFreshness() {
        let evmNetworkIDs = [
            "eth", "bsc", "arbitrum", "base", "polygon", "optimism",
            "avalanche", "gnosis", "linea", "scroll", "taiko", "telos",
            "xlayer"
        ]
        let cases: [(networkIDs: [String], tier: SendNetworkFeeTier)] = [
            (
                evmNetworkIDs,
                SendNetworkFeeTier(
                    preset: .fastest,
                    model: .evmEIP1559,
                    primaryValue: "2",
                    secondaryValue: "1"
                )
            ),
            (
                ["bitcoin", "bitcoin_cash", "litecoin"],
                SendNetworkFeeTier(
                    preset: .fastest,
                    model: .utxoPerVByte,
                    primaryValue: "1",
                    secondaryValue: nil
                )
            ),
            (
                ["dogecoin"],
                SendNetworkFeeTier(
                    preset: .fastest, model: .utxoPerVByte,
                    primaryValue: "1000", secondaryValue: nil
                )
            ),
            (
                [SolanaConstants.networkID],
                SendNetworkFeeTier(
                    preset: .fastest,
                    model: .solanaPriority,
                    primaryValue: "0",
                    secondaryValue: nil
                )
            ),
            (
                [TronConstants.networkID],
                SendNetworkFeeTier(
                    preset: .fastest,
                    model: .tronProtocol,
                    primaryValue: "100",
                    secondaryValue: "1000"
                )
            ),
            (
                [TONConstants.networkID],
                SendNetworkFeeTier(
                    preset: .fastest,
                    model: .tonProtocol,
                    primaryValue: "50000000",
                    secondaryValue: "100000000"
                )
            ),
            (
                [SuiConstants.networkID],
                SendNetworkFeeTier(
                    preset: .fastest,
                    model: .suiProtocol,
                    primaryValue: "10000000",
                    secondaryValue: "750"
                )
            ),
            (
                [XRPConstants.networkID],
                SendNetworkFeeTier(
                    preset: .fastest,
                    model: .xrpProtocol,
                    primaryValue: "10",
                    secondaryValue: nil
                )
            ),
            (
                [NEARConstants.networkID],
                SendNetworkFeeTier(
                    preset: .fastest,
                    model: .nearProtocol,
                    primaryValue: "10000000000000000000000",
                    secondaryValue: "100000000"
                )
            ),
            (
                [AptosConstants.networkID],
                SendNetworkFeeTier(
                    preset: .fastest,
                    model: .aptosProtocol,
                    primaryValue: "2000000",
                    secondaryValue: "100"
                )
            ),
            (
                [StellarConstants.networkID],
                SendNetworkFeeTier(
                    preset: .fastest,
                    model: .stellarProtocol,
                    primaryValue: "100",
                    secondaryValue: nil
                )
            )
        ]
        let fetchedAt = Date().addingTimeInterval(-1)
        for item in cases {
            for networkID in item.networkIDs {
                let tiers = [
                    SendNetworkFeeTier(
                        preset: .fastest,
                        model: item.tier.model,
                        primaryValue: item.tier.primaryValue,
                        secondaryValue: item.tier.secondaryValue
                    ),
                    SendNetworkFeeTier(
                        preset: .standard,
                        model: item.tier.model,
                        primaryValue: item.tier.primaryValue,
                        secondaryValue: item.tier.secondaryValue
                    ),
                    SendNetworkFeeTier(
                        preset: .economy,
                        model: item.tier.model,
                        primaryValue: item.tier.primaryValue,
                        secondaryValue: item.tier.secondaryValue
                    )
                ]
                #expect(
                    SendNetworkFeeAPIClient.isValid(
                        SendNetworkFeeQuote(
                            networkID: networkID,
                            provider: "test-mainnet-provider",
                            fetchedAt: fetchedAt,
                            expiresAt: fetchedAt.addingTimeInterval(30),
                            tiers: tiers
                        ),
                        expectedNetworkID: networkID
                    ),
                    "Fee validation rejected \(networkID)."
                )
            }
        }

        let expired = SendNetworkFeeQuote(
            networkID: "bitcoin",
            provider: "test-mainnet-provider",
            fetchedAt: Date().addingTimeInterval(-90),
            expiresAt: Date().addingTimeInterval(-30),
            tiers: [
                SendNetworkFeeTier(
                    preset: .fastest,
                    model: .utxoPerVByte,
                    primaryValue: "1",
                    secondaryValue: nil
                ),
                SendNetworkFeeTier(
                    preset: .standard,
                    model: .utxoPerVByte,
                    primaryValue: "1",
                    secondaryValue: nil
                ),
                SendNetworkFeeTier(
                    preset: .economy,
                    model: .utxoPerVByte,
                    primaryValue: "1",
                    secondaryValue: nil
                )
            ]
        )
        #expect(
            !SendNetworkFeeAPIClient.isValid(
                expired,
                expectedNetworkID: "bitcoin"
            )
        )
        #expect(
            SendNetworkFeeAPIClient.isValidForSessionReuse(
                expired,
                expectedNetworkID: "bitcoin"
            )
        )
    }

    @Test
    func quoteClientDecodesAndValidatesAllPresets() async throws {
        let baseURL = try #require(URL(string: "https://fees.example"))
        let client = try SendNetworkFeeAPIClient(
            baseURL: baseURL
        ) { request in
            #expect(
                request.url?.absoluteString
                    == "https://fees.example/v1/network-fees/eth"
            )
            let response = try #require(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (Self.validQuoteData, response)
        }

        let quote = try await client.quote(for: "eth")

        #expect(quote.networkID == "eth")
        #expect(quote.provider == "ankr")
        #expect(quote.tier(for: .fastest)?.primaryValue == "42000000000")
        #expect(quote.tier(for: .economy)?.secondaryValue == "1000000000")
    }

    @Test
    func quoteClientRetriesOneTransientFailureAndThenSucceeds() async throws {
        let baseURL = try #require(URL(string: "https://fees.example"))
        let probe = SendNetworkFeeRequestSequence(
            responses: [
                (503, Data(
                    #"{"error":{"code":"providers_unavailable"}}"#.utf8
                )),
                (200, Self.validQuoteData)
            ]
        )
        let client = try SendNetworkFeeAPIClient(
            baseURL: baseURL,
            requestExecutor: { request in
                try await probe.execute(request)
            }
        )

        let quote = try await client.quote(for: "eth")

        #expect(quote.networkID == "eth")
        #expect(await probe.requestCount() == 2)
    }

    @Test
    func retryPolicyDoesNotReplayDefinitiveOrCancelledReads() async {
        let definitiveProbe = SendNetworkFeeOperationProbe(
            error: SendNetworkFeeAPIError.server(
                status: 404,
                code: "network_fee_network_unsupported"
            )
        )
        await #expect(throws: SendNetworkFeeAPIError.self) {
            try await SendNetworkFeeAPIClient.retryingQuote(
                sleeper: { _ in }
            ) {
                try await definitiveProbe.run()
            }
        }
        #expect(await definitiveProbe.attemptCount() == 1)

        let cancellationProbe = SendNetworkFeeOperationProbe(
            error: CancellationError()
        )
        await #expect(throws: CancellationError.self) {
            try await SendNetworkFeeAPIClient.retryingQuote(
                sleeper: { _ in }
            ) {
                try await cancellationProbe.run()
            }
        }
        #expect(await cancellationProbe.attemptCount() == 1)
    }

    @Test
    func retryPolicyExhaustsExactlyTwoAttemptsForDirectProviderFailure()
        async
    {
        let probe = SendNetworkFeeOperationProbe(
            error: SendNetworkFeeDirectProviderProbeError.unavailable
        )

        await #expect(throws: SendNetworkFeeDirectProviderProbeError.self) {
            try await SendNetworkFeeAPIClient.retryingQuote(
                sleeper: { _ in }
            ) {
                try await probe.run()
            }
        }

        #expect(await probe.attemptCount() == 2)
    }

    @Test
    func quoteClientPreservesServerFailureCode() async throws {
        let baseURL = try #require(URL(string: "https://fees.example"))
        let client = try SendNetworkFeeAPIClient(
            baseURL: baseURL
        ) { request in
            let response = try #require(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            let data = Data(
                #"{"error":{"code":"providers_unavailable"}}"#.utf8
            )
            return (data, response)
        }

        await #expect(
            throws:
                SendNetworkFeeAPIError.server(
                    status: 503,
                    code: "providers_unavailable"
                )
        ) {
            try await client.quote(for: "polygon")
        }
    }

    @Test
    func quoteClientRejectsIncompletePresetResponse() async throws {
        let baseURL = try #require(URL(string: "https://fees.example"))
        let client = try SendNetworkFeeAPIClient(
            baseURL: baseURL
        ) { request in
            let response = try #require(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            let data = Data(
                """
                {
                  "quote": {
                    "networkID": "eth",
                    "provider": "ankr",
                    "fetchedAt": "2026-07-27T00:00:00Z",
                    "expiresAt": "2026-07-27T00:00:15Z",
                    "tiers": []
                  }
                }
                """.utf8
            )
            return (data, response)
        }

        await #expect(throws: SendNetworkFeeAPIError.self) {
            try await client.quote(for: "eth")
        }
    }

    @Test
    func databaseBoundPreferencesLoadEveryDefaultWithoutGlobalRuntime()
        async throws
    {
        WalletDatabaseRuntime.clear()
        defer { WalletDatabaseRuntime.clear() }
        let database = try WalletDatabase.temporary()
        let repository = SendNetworkFeePreferenceRepository(
            database: database
        )

        #expect(!WalletDatabaseRuntime.isReady)
        for networkID in SendNetworkFeeAPIClient
            .supportedQuoteNetworkIDs.sorted() {
            #expect(
                try await repository.policy(for: networkID) == .fastest,
                "Expected database-bound default for \(networkID)."
            )
            let quote = try SendNetworkFeeAPIClient.defaultQuote(
                for: networkID
            )
            #expect(quote.tier(for: .fastest) != nil)
        }

        try await repository.savePreset(.economy)
        #expect(
            try await repository.policy(for: "polygon")
                == SendNetworkFeePolicy.preset(.economy)
        )

        let custom = SendNetworkFeeCustomValue(
            model: .utxoPerVByte,
            primaryValue: "25",
            secondaryValue: nil,
            totalBudgetAtomic: "5650"
        )
        try await repository.saveCustom(custom, for: "bitcoin")
        #expect(
            try await repository.policy(for: "bitcoin")
                == SendNetworkFeePolicy.custom(custom)
        )
        #expect(
            try await repository.policy(for: "eth") == .fastest
        )
    }

}

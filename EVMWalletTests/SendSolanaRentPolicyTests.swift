import Foundation
import Testing
@testable import Aperture

struct SendSolanaRentPolicyTests {
    @Test
    func everySupportedNetworkHasAnExplicitRecipientRule() {
        let networkIDs = AssetNetworkSelectorOption.allSupported.map(\.id)

        #expect(networkIDs.count == 25)
        #expect(Set(networkIDs).count == networkIDs.count)
        #expect(
            SendRecipientRequirementNetworkRule.rule(
                for: "future-mainnet"
            ) == .unsupported
        )
        #expect(
            networkIDs.allSatisfy {
                SendRecipientRequirementNetworkRule.rule(for: $0)
                    != .unsupported
            }
        )
        #expect(
            Set(
                networkIDs.filter {
                    SendRecipientRequirementNetworkRule.rule(for: $0)
                        != .noActivationMinimum
                }
            ) == Set([
                StellarConstants.networkID,
                XRPConstants.networkID,
                SolanaConstants.networkID,
                NEARConstants.networkID
            ])
        )
    }

    @Test
    func stellarInactiveAccountUsesTheLiveTwoBaseReserveMinimum()
        throws
    {
        let minimum = SendRecipientMinimum(
            amountAtomic: "10000000",
            decimals: StellarConstants.decimals,
            symbol: StellarConstants.nativeSymbol,
            reason: .stellarAccountReserve
        )
        let native = try SendRecipientRequirementChecker
            .stellarRequirement(
                accountExists: false,
                baseReserveAtomic: "5000000",
                isNative: true
            )
        let token = try SendRecipientRequirementChecker
            .stellarRequirement(
                accountExists: false,
                baseReserveAtomic: "5000000",
                isNative: false
            )

        #expect(native.minimum == minimum)
        #expect(
            !native.permits(
                assetAmount: "0.9999999",
                assetDecimals: StellarConstants.decimals
            )
        )
        #expect(
            native.permits(
                assetAmount: "1",
                assetDecimals: StellarConstants.decimals
            )
        )
        #expect(token.blocker == .stellarTokenAccountInactive(minimum))
        #expect(
            try SendRecipientRequirementChecker.stellarRequirement(
                accountExists: true,
                baseReserveAtomic: "5000000",
                isNative: true
            ) == .none
        )
    }

    @Test
    func xrpInactiveAccountUsesTheLiveBaseReserveMinimum() {
        let minimum = SendRecipientMinimum(
            amountAtomic: "1000000",
            decimals: XRPConstants.decimals,
            symbol: XRPConstants.nativeSymbol,
            reason: .xrpAccountReserve
        )
        let native = SendRecipientRequirementChecker.xrpRequirement(
            accountExists: false,
            baseReserveDrops: 1_000_000,
            isNative: true
        )
        let token = SendRecipientRequirementChecker.xrpRequirement(
            accountExists: false,
            baseReserveDrops: 1_000_000,
            isNative: false
        )

        #expect(native.minimum == minimum)
        #expect(
            !native.permits(
                assetAmount: "0.999999",
                assetDecimals: XRPConstants.decimals
            )
        )
        #expect(
            native.permits(
                assetAmount: "1",
                assetDecimals: XRPConstants.decimals
            )
        )
        #expect(token.blocker == .xrpTokenAccountInactive(minimum))
        #expect(
            SendRecipientRequirementChecker.xrpRequirement(
                accountExists: true,
                baseReserveDrops: 1_000_000,
                isNative: true
            ) == .none
        )
    }

    @Test
    func solanaRecipientUsesTheExactLiveRentShortfall() {
        let missing = SendRecipientRequirementChecker.solanaRequirement(
            currentBalance: nil,
            rentMinimum: 890_880
        )
        let shortfall = SendRecipientRequirementChecker.solanaRequirement(
            currentBalance: 110_509,
            rentMinimum: 890_880
        )

        #expect(missing.minimum?.amountAtomic == "890880")
        #expect(missing.minimum?.displayAmount == "0.00089088")
        #expect(shortfall.minimum?.amountAtomic == "780371")
        #expect(
            !shortfall.permits(
                assetAmount: "0.000780370",
                assetDecimals: SolanaConstants.decimals
            )
        )
        #expect(
            shortfall.permits(
                assetAmount: "0.000780371",
                assetDecimals: SolanaConstants.decimals
            )
        )
        #expect(
            SendRecipientRequirementChecker.solanaRequirement(
                currentBalance: 890_880,
                rentMinimum: 890_880
            ) == .none
        )
    }

    @Test
    func nearMissingAccountPolicyDistinguishesNamedAndImplicit() {
        #expect(
            SendRecipientRequirementChecker.nearRequirement(
                accountExists: false,
                kind: .named,
                isNative: true
            ).blocker == .nearNamedAccountMissing
        )
        #expect(
            SendRecipientRequirementChecker.nearRequirement(
                accountExists: false,
                kind: .implicit,
                isNative: true
            ) == .none
        )
        #expect(
            SendRecipientRequirementChecker.nearRequirement(
                accountExists: false,
                kind: .implicit,
                isNative: false
            ).blocker == .nearTokenAccountMissing
        )
        #expect(
            SendRecipientRequirementChecker.nearRequirement(
                accountExists: true,
                kind: .named,
                isNative: false
            ) == .none
        )
    }

    @Test
    @MainActor
    func nativeNEARImplicitRecipientIsImmediatelyReviewable() throws {
        let recipient =
            "288736a61dd2d19345a6badd00f067b7e3048826840dbd76e7c68e49de4a5814"
        let native = SendAssetChoice(
            id: "near:native",
            name: "NEAR",
            symbol: NEARConstants.nativeSymbol,
            networkID: NEARConstants.networkID,
            networkName: "NEAR",
            blockchain: .near,
            contractAddress: nil,
            decimals: NEARConstants.decimals,
            logoSource: .nativeCoin(blockchain: .near),
            networkLogoSource: .network(blockchain: .near),
            balance: Decimal(string: "6.04222025")!,
            fiatValue: Decimal(string: "11.33")!
        )
        let token = SendAssetChoice(
            id: "near:usdt.tether-token.near",
            name: "Tether USD",
            symbol: "USDT",
            networkID: NEARConstants.networkID,
            networkName: "NEAR",
            blockchain: .near,
            contractAddress: "usdt.tether-token.near",
            decimals: 6,
            logoSource: .unavailable,
            networkLogoSource: .network(blockchain: .near),
            balance: 10,
            fiatValue: 10
        )
        let currency = WalletCurrencyContext(code: "USD", ratePerUSD: 1)
        let assetAmount = try SendAmountEntryConverter.assetAmount(
            from: "0.20",
            mode: .localCurrency,
            usesMaximumBalance: false,
            asset: native,
            currency: currency
        )
        let model = SendRecipientRequirementModel()

        #expect(NEARAddress.kind(recipient) == .implicit)
        #expect(SendFlowPlanner.amountIssue(assetAmount, asset: native) == nil)
        #expect(
            !SendRecipientRequirementNetworkRule.requiresLiveLookup(
                for: native,
                recipient: recipient
            )
        )
        #expect(
            SendRecipientRequirementInput(
                asset: native,
                sourceRecipient: recipient,
                checkedRecipient: recipient
            ) == nil
        )
        #expect(
            model.allowsReview(
                asset: native,
                sourceRecipient: recipient,
                assetAmount: assetAmount,
                baseFormIsValid: true
            )
        )
        #expect(
            SendRecipientRequirementNetworkRule.requiresLiveLookup(
                for: native,
                recipient: "recipient-preflight.near"
            )
        )
        #expect(
            SendRecipientRequirementInput(
                asset: token,
                sourceRecipient: recipient,
                checkedRecipient: recipient
            ) != nil
        )

        let request = SendPaymentRequest(
            source: .nearURI,
            recipient: recipient,
            candidateNetworkIDs: [NEARConstants.networkID],
            requestedNetworkID: NEARConstants.networkID,
            requestedAsset: .native,
            requestedAmount: .userUnits(assetAmount),
            label: nil,
            message: nil,
            memo: nil,
            references: []
        )
        guard case .review = try SendFlowPlanner.initialRoute(
            for: request,
            choices: [native]
        ) else {
            Issue.record("Native implicit NEAR incorrectly waited for lookup")
            return
        }
    }

    @Test
    func liveRecipientProviderFailuresKeepTheirActualCause() {
        let failures = [
            SendRecipientRequirementChecker.failure(
                networkName: "Stellar",
                error: StellarProviderError.http(
                    status: 503,
                    code: "over_capacity"
                )
            ),
            SendRecipientRequirementChecker.failure(
                networkName: "XRP Ledger",
                error: XRPProviderError.rpc(
                    code: -32_603,
                    message: "too_busy"
                )
            ),
            SendRecipientRequirementChecker.failure(
                networkName: "NEAR",
                error: NEARProviderError.http(
                    status: 403,
                    code: "near_method_forbidden"
                )
            ),
            SendRecipientRequirementChecker.failure(
                networkName: "Solana",
                error: SendTransactionSubmissionError.provider(
                    networkID: SolanaConstants.networkID,
                    code: "rpc_-32005",
                    message: "rate limit"
                )
            ),
            SendRecipientRequirementChecker.failure(
                networkName: "TRON",
                error: SendTransactionSubmissionError.provider(
                    networkID: TronConstants.networkID,
                    code: "http_429",
                    message: "request rate exceeded"
                )
            )
        ]

        #expect(failures[0].diagnosticCode.contains("503"))
        #expect(failures[0].providerMessage == "over_capacity")
        #expect(failures[1].diagnosticCode.contains("-32603"))
        #expect(failures[1].providerMessage == "too_busy")
        #expect(failures[2].diagnosticCode.contains("403"))
        #expect(failures[2].providerMessage == "near_method_forbidden")
        #expect(failures[3].diagnosticCode == "rpc_-32005")
        #expect(failures[3].providerMessage == "rate limit")
        #expect(failures[4].diagnosticCode == "http_429")
        #expect(failures[4].providerMessage == "request rate exceeded")
        #expect(
            failures.allSatisfy {
                $0.localizedMessage.contains($0.diagnosticCode)
                    && $0.localizedMessage.contains($0.providerMessage)
            }
        )
    }

    @Test
    @MainActor
    func amountFocusDoesNotCancelAnyLiveRecipientCheck() async throws {
        let fixtures: [(SendAssetChoice, String)] = [
            (
                Self.liveRequirementAsset(
                    networkID: StellarConstants.networkID,
                    name: "Stellar",
                    symbol: StellarConstants.nativeSymbol,
                    blockchain: .stellar,
                    decimals: StellarConstants.decimals
                ),
                "GBBEEQSCIJBEEQSCIJBEEQSCIJBEEQSCIJBEEQSCIJBEEQSCIJBEFZSP"
            ),
            (
                Self.liveRequirementAsset(
                    networkID: XRPConstants.networkID,
                    name: "XRP Ledger",
                    symbol: XRPConstants.nativeSymbol,
                    blockchain: .xrp,
                    decimals: XRPConstants.decimals
                ),
                "rnBFvgZphmN39GWzUJeUitaP22Fr9be75H"
            ),
            (
                Self.liveRequirementAsset(
                    networkID: SolanaConstants.networkID,
                    name: "Solana",
                    symbol: SolanaConstants.nativeSymbol,
                    blockchain: .solana,
                    decimals: SolanaConstants.decimals
                ),
                "5TeWSsjg2gbxCyWVniXeCmwM7UtHTCK7svzJr5xYJzHf"
            ),
            (
                Self.liveRequirementAsset(
                    networkID: NEARConstants.networkID,
                    name: "NEAR",
                    symbol: NEARConstants.nativeSymbol,
                    blockchain: .near,
                    decimals: NEARConstants.decimals
                ),
                "recipient-preflight.near"
            )
        ]

        for (asset, recipient) in fixtures {
            let model = SendRecipientRequirementModel { asset, _ in
                try await Task.sleep(for: .milliseconds(20))
                return try Self.liveRequirementResult(for: asset.networkID)
            }
            let input = try #require(
                SendRecipientRequirementInput(
                    asset: asset,
                    sourceRecipient: recipient,
                    checkedRecipient: recipient
                )
            )

            model.schedule(
                input: input,
                asset: asset,
                debounce: .milliseconds(0)
            )
            await Task.yield()
            #expect(
                model.presentation(
                    asset: asset,
                    sourceRecipient: recipient,
                    assetAmount: "1"
                )?.message
                    == WalletLocalization.string(
                        "send.recipient.requirement.checking"
                    )
            )
            await model.waitForScheduledRefresh()
            #expect(
                model.allowsReview(
                    asset: asset,
                    sourceRecipient: recipient,
                    assetAmount: "1",
                    baseFormIsValid: true
                )
            )
        }
    }

    @Test
    @MainActor
    func activationMinimumNoticesOnlyAppearBelowTheRequiredAmount()
        async throws
    {
        let fixtures: [(
            asset: SendAssetChoice,
            recipient: String,
            requirement: SendRecipientRequirement,
            below: String,
            exact: String,
            above: String
        )] = [
            (
                Self.liveRequirementAsset(
                    networkID: StellarConstants.networkID,
                    name: "Stellar",
                    symbol: StellarConstants.nativeSymbol,
                    blockchain: .stellar,
                    decimals: StellarConstants.decimals
                ),
                "GBBEEQSCIJBEEQSCIJBEEQSCIJBEEQSCIJBEEQSCIJBEEQSCIJBEFZSP",
                try Self.liveRequirementResult(
                    for: StellarConstants.networkID
                ),
                "0.5",
                "1",
                "2"
            ),
            (
                Self.liveRequirementAsset(
                    networkID: XRPConstants.networkID,
                    name: "XRP Ledger",
                    symbol: XRPConstants.nativeSymbol,
                    blockchain: .xrp,
                    decimals: XRPConstants.decimals
                ),
                "rnBFvgZphmN39GWzUJeUitaP22Fr9be75H",
                try Self.liveRequirementResult(for: XRPConstants.networkID),
                "0.5",
                "1",
                "2"
            ),
            (
                Self.liveRequirementAsset(
                    networkID: SolanaConstants.networkID,
                    name: "Solana",
                    symbol: SolanaConstants.nativeSymbol,
                    blockchain: .solana,
                    decimals: SolanaConstants.decimals
                ),
                "5TeWSsjg2gbxCyWVniXeCmwM7UtHTCK7svzJr5xYJzHf",
                try Self.liveRequirementResult(
                    for: SolanaConstants.networkID
                ),
                "0.000890879",
                "0.00089088",
                "0.001"
            )
        ]

        for fixture in fixtures {
            let model = SendRecipientRequirementModel { _, _ in
                fixture.requirement
            }
            let input = try #require(
                SendRecipientRequirementInput(
                    asset: fixture.asset,
                    sourceRecipient: fixture.recipient,
                    checkedRecipient: fixture.recipient
                )
            )
            await model.refresh(input: input, asset: fixture.asset)
            let expectedMessage = try #require(fixture.requirement.minimum)
                .localizedMessage
            // Cross the threshold in both directions, then clear the field.
            // Each edit must use the current amount, without another lookup.
            let amounts: [(String?, Bool, Bool)] = [
                (nil, false, false),
                ("", false, false),
                ("0", false, false),
                ("invalid", false, false),
                (fixture.below, true, false),
                (fixture.exact, false, true),
                (fixture.above, false, true),
                (fixture.below, true, false),
                (nil, false, false)
            ]

            for (amount, showsWarning, permitsReview) in amounts {
                let presentation = model.presentation(
                    asset: fixture.asset,
                    sourceRecipient: fixture.recipient,
                    assetAmount: amount
                )
                if showsWarning {
                    #expect(presentation?.message == expectedMessage)
                    #expect(presentation?.isBlocking == true)
                } else {
                    #expect(presentation == nil)
                }
                #expect(
                    model.allowsReview(
                        asset: fixture.asset,
                        sourceRecipient: fixture.recipient,
                        assetAmount: amount,
                        baseFormIsValid: true
                    ) == permitsReview
                )
            }
        }
    }

    @Test
    func completeLiveRequirementRequestsCannotSkipRecipientPreflight()
        throws
    {
        let fixtures: [(
            source: SendPaymentRequestSource,
            recipient: String,
            networkID: String,
            name: String,
            symbol: String,
            blockchain: WalletBlockchain,
            decimals: Int
        )] = [
            (
                .stellarURI,
                "GBBEEQSCIJBEEQSCIJBEEQSCIJBEEQSCIJBEEQSCIJBEEQSCIJBEFZSP",
                StellarConstants.networkID,
                "Stellar",
                StellarConstants.nativeSymbol,
                .stellar,
                StellarConstants.decimals
            ),
            (
                .xrpURI,
                "rnBFvgZphmN39GWzUJeUitaP22Fr9be75H",
                XRPConstants.networkID,
                "XRP Ledger",
                XRPConstants.nativeSymbol,
                .xrp,
                XRPConstants.decimals
            ),
            (
                .solanaPayURI,
                "5TeWSsjg2gbxCyWVniXeCmwM7UtHTCK7svzJr5xYJzHf",
                SolanaConstants.networkID,
                "Solana",
                SolanaConstants.nativeSymbol,
                .solana,
                SolanaConstants.decimals
            ),
            (
                .nearURI,
                "recipient-preflight.near",
                NEARConstants.networkID,
                "NEAR",
                NEARConstants.nativeSymbol,
                .near,
                NEARConstants.decimals
            )
        ]

        for fixture in fixtures {
            let request = SendPaymentRequest(
                source: fixture.source,
                recipient: fixture.recipient,
                candidateNetworkIDs: [fixture.networkID],
                requestedNetworkID: fixture.networkID,
                requestedAsset: .native,
                requestedAmount: .userUnits("1"),
                label: nil,
                message: nil,
                memo: nil,
                references: []
            )
            let choice = SendAssetChoice(
                id: "\(fixture.networkID):native",
                name: fixture.name,
                symbol: fixture.symbol,
                networkID: fixture.networkID,
                networkName: fixture.name,
                blockchain: fixture.blockchain,
                contractAddress: nil,
                decimals: fixture.decimals,
                logoSource: .nativeCoin(
                    blockchain: fixture.blockchain
                ),
                networkLogoSource: .network(
                    blockchain: fixture.blockchain
                ),
                balance: 10,
                fiatValue: 0
            )

            let route = try SendFlowPlanner.initialRoute(
                for: request,
                choices: [choice]
            )
            switch route {
            case .recipient, .amount: break
            default:
                Issue.record(
                    "\(fixture.name) skipped recipient preflight"
                )
                continue
            }
        }
    }

    @Test
    @MainActor
    func reviewIsDisabledUntilADirectLiveAddressIsChecked() {
        let asset = SendAssetChoice(
            id: StellarConstants.nativeAssetID,
            name: "Stellar Lumens",
            symbol: StellarConstants.nativeSymbol,
            networkID: StellarConstants.networkID,
            networkName: "Stellar",
            blockchain: .stellar,
            contractAddress: nil,
            decimals: StellarConstants.decimals,
            logoSource: .nativeCoin(blockchain: .stellar),
            networkLogoSource: .network(blockchain: .stellar),
            balance: 10,
            fiatValue: 0
        )
        let model = SendRecipientRequirementModel()

        #expect(
            !model.allowsReview(
                asset: asset,
                sourceRecipient:
                    "GBBEEQSCIJBEEQSCIJBEEQSCIJBEEQSCIJBEEQSCIJBEEQSCIJBEFZSP",
                assetAmount: "1",
                baseFormIsValid: true
            )
        )
    }

    @Test
    func absentRecipientNeedsTheFullRentMinimum() {
        #expect(
            SendSolanaRentPolicy.requiredRecipientFunding(
                currentBalance: nil,
                rentMinimum: 890_880
            ) == 890_880
        )
    }

    @Test
    func rentPayingRecipientNeedsOnlyItsShortfall() {
        #expect(
            SendSolanaRentPolicy.requiredRecipientFunding(
                currentBalance: 110_509,
                rentMinimum: 890_880
            ) == 780_371
        )
    }

    @Test
    func rentExemptRecipientNeedsNoMinimumTransfer() {
        #expect(
            SendSolanaRentPolicy.requiredRecipientFunding(
                currentBalance: 890_880,
                rentMinimum: 890_880
            ) == 0
        )
        #expect(
            SendSolanaRentPolicy.requiredRecipientFunding(
                currentBalance: 1_000_000,
                rentMinimum: 890_880
            ) == 0
        )
    }

    @Test
    func rentExemptSenderMayRemainExemptOrCloseToZero() {
        #expect(
            SendSolanaRentPolicy.permitsSenderTransition(
                preBalance: 2_000_000,
                postBalance: 890_880,
                rentMinimum: 890_880
            )
        )
        #expect(
            SendSolanaRentPolicy.permitsSenderTransition(
                preBalance: 2_000_000,
                postBalance: 0,
                rentMinimum: 890_880
            )
        )
    }

    @Test
    func rentExemptSenderCannotBeStrandedBelowMinimum() {
        #expect(
            !SendSolanaRentPolicy.permitsSenderTransition(
                preBalance: 2_000_000,
                postBalance: 100_000,
                rentMinimum: 890_880
            )
        )
    }

    @Test
    func existingRentPayingSenderMayOnlyDecrease() {
        #expect(
            SendSolanaRentPolicy.permitsSenderTransition(
                preBalance: 500_000,
                postBalance: 400_000,
                rentMinimum: 890_880
            )
        )
        #expect(
            !SendSolanaRentPolicy.permitsSenderTransition(
                preBalance: 500_000,
                postBalance: 600_000,
                rentMinimum: 890_880
            )
        )
    }

    @Test
    @MainActor
    func networksWithoutRecipientMinimumsNeverShowActivationNotices()
        async throws
    {
        let networks = AssetNetworkSelectorOption.allSupported.filter {
            SendRecipientRequirementNetworkRule.rule(for: $0.id)
                == .noActivationMinimum
        }
        #expect(networks.count == 21)
        for network in networks {
            let asset = Self.liveRequirementAsset(
                networkID: network.id, name: network.localizedName,
                symbol: "NATIVE", blockchain: network.blockchain, decimals: 6
            )
            #expect(!SendRecipientRequirementNetworkRule.requiresLiveLookup(for: asset))
            let requirement = try await SendRecipientRequirementChecker.shared
                .check(asset: asset, recipient: "unused-by-this-policy")
            #expect(requirement == .none)
            for amount in [nil, "0", "0.000001", "100"] as [String?] {
                #expect(requirement.presentation(assetAmount: amount, assetDecimals: 6) == nil)
            }
        }
    }

    @Test
    @MainActor
    func tronAmountAndCompleteRequestsDoNotWaitForAnActivationAdvisory()
        throws
    {
        let asset = Self.liveRequirementAsset(
            networkID: TronConstants.networkID, name: "TRON",
            symbol: "TRX", blockchain: .tron, decimals: 6
        )
        let recipient = "TStRwBaLtnrFbZbh57km22V45KDBTnbbVn"
        let model = SendRecipientRequirementModel { _, _ in
            Issue.record("TRON amount entry must not make an activation lookup")
            return .none
        }
        let input = SendRecipientRequirementInput(
            asset: asset, sourceRecipient: recipient, checkedRecipient: recipient
        )
        #expect(input == nil)
        model.schedule(input: input, asset: asset, debounce: .zero)
        for amount in ["0.000001", "0.1", "1", "5.884412"] {
            #expect(model.allowsReview(
                asset: asset, sourceRecipient: recipient,
                assetAmount: amount, baseFormIsValid: true
            ))
            #expect(model.presentation(
                asset: asset, sourceRecipient: recipient, assetAmount: amount
            ) == nil)
        }
        #expect(!model.allowsReview(
            asset: asset, sourceRecipient: recipient,
            assetAmount: "0", baseFormIsValid: false
        ))
        let request = SendPaymentRequest(
            source: .tronURI, recipient: recipient,
            candidateNetworkIDs: [asset.networkID], requestedNetworkID: asset.networkID,
            requestedAsset: .native, requestedAmount: .userUnits("0.000001"),
            label: nil, message: nil, memo: nil, references: []
        )
        guard case .review = try SendFlowPlanner.initialRoute(for: request, choices: [asset]) else {
            Issue.record("A valid TRON request should proceed to fee review")
            return
        }
    }

    @Test
    func increasingATokenAmountCannotRemoveAnAccountExistenceBlocker() throws {
        let requirements = [
            try SendRecipientRequirementChecker.stellarRequirement(
                accountExists: false, baseReserveAtomic: "5000000", isNative: false
            ),
            SendRecipientRequirementChecker.xrpRequirement(
                accountExists: false, baseReserveDrops: 1_000_000, isNative: false
            ),
            SendRecipientRequirementChecker.nearRequirement(
                accountExists: false, kind: .implicit, isNative: false
            ),
            SendRecipientRequirementChecker.nearRequirement(
                accountExists: false, kind: .named, isNative: true
            )
        ]
        for requirement in requirements {
            #expect(requirement.blocker != nil)
            for amount in [nil, "0.1", "1", "1000000"] as [String?] {
                #expect(!requirement.permits(assetAmount: amount, assetDecimals: 6))
                #expect(requirement.presentation(
                    assetAmount: amount, assetDecimals: 6
                )?.isBlocking == true)
            }
        }
    }

    private static func liveRequirementAsset(
        networkID: String,
        name: String,
        symbol: String,
        blockchain: WalletBlockchain,
        decimals: Int
    ) -> SendAssetChoice {
        SendAssetChoice(
            id: "\(networkID):native",
            name: name,
            symbol: symbol,
            networkID: networkID,
            networkName: name,
            blockchain: blockchain,
            contractAddress: nil,
            decimals: decimals,
            logoSource: .nativeCoin(blockchain: blockchain),
            networkLogoSource: .network(blockchain: blockchain),
            balance: 10,
            fiatValue: 0
        )
    }

    private static func liveRequirementResult(
        for networkID: String
    ) throws -> SendRecipientRequirement {
        switch networkID {
        case StellarConstants.networkID:
            try SendRecipientRequirementChecker.stellarRequirement(
                accountExists: false,
                baseReserveAtomic: "5000000",
                isNative: true
            )
        case XRPConstants.networkID:
            SendRecipientRequirementChecker.xrpRequirement(
                accountExists: false,
                baseReserveDrops: 1_000_000,
                isNative: true
            )
        case SolanaConstants.networkID:
            SendRecipientRequirementChecker.solanaRequirement(
                currentBalance: nil,
                rentMinimum: 890_880
            )
        case NEARConstants.networkID:
            SendRecipientRequirementChecker.nearRequirement(
                accountExists: true,
                kind: .named,
                isNative: true
            )
        default:
            throw SendTransactionSubmissionError.unsupportedNetwork
        }
    }
}

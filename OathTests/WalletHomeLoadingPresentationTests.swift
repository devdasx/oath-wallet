import Foundation
import Testing
@testable import Aperture

struct WalletHomeLoadingPresentationTests {
    @Test
    func everySharedEmptyStateUsesTheDashedCircleSymbol() {
        #expect(
            WalletEmptyStateSymbol.systemName == "circle.dashed"
        )
    }

    @Test
    func loadingStateDisplaysRealEmptyValuesInsteadOfPlaceholders() {
        let snapshot = WalletHomeLoadState.loading.displayedSnapshot

        #expect(snapshot?.totalBalance == 0)
        #expect(snapshot?.assets.isEmpty == true)
        #expect(snapshot?.transactions.isEmpty == true)
    }

    @Test
    func contentStateKeepsThePersistedSnapshotVisible() {
        let persisted = WalletHomeSnapshot(
            totalBalance: 42,
            assets: [],
            transactions: []
        )

        let snapshot = WalletHomeLoadState
            .content(persisted)
            .displayedSnapshot

        #expect(snapshot?.totalBalance == 42)
    }

    @Test
    func failedStateStillUsesTheExistingFailureScreen() {
        #expect(WalletHomeLoadState.failed.displayedSnapshot == nil)
    }

    @Test
    func synchronizationReportDoesNotTreatFailuresAsFreshData() {
        let report = WalletSynchronizationReport(
            outcomes: [
                .failure(
                    .evm,
                    stage: .configuration,
                    error: AnkrAPIError.missingConfiguration
                ),
                .failure(
                    .solana,
                    stage: .providerRead,
                    error: URLError(.timedOut)
                )
            ]
        )

        #expect(report.hasFailures)
        #expect(!report.didPersistData)
        #expect(report.failures.count == 2)
    }

    @Test
    func partialSynchronizationKeepsFreshSuccessfulDataVisible() {
        let report = WalletSynchronizationReport(
            outcomes: [
                .success(.tron),
                .failure(
                    .bitcoinFamily,
                    stage: .providerRead,
                    error: URLError(.cannotConnectToHost)
                )
            ]
        )

        #expect(report.didPersistData)
        #expect(report.hasFailures)
        #expect(
            report.failures.first?.publicCode
                == "transport_error_-1004"
        )
    }

    @Test
    func synchronizationFailureKeepsActionableProviderCause() {
        let missingConfiguration = WalletChainSyncFailure(
            source: .evm,
            stage: .configuration,
            error: AnkrAPIError.missingConfiguration
        )
        let rejectedCredential = WalletChainSyncFailure(
            source: .tron,
            stage: .providerRead,
            error: AnkrAPIError.httpFailure(
                statusCode: 401,
                message: "credential rejected"
            )
        )

        #expect(missingConfiguration.kind == .configurationMissing)
        #expect(
            missingConfiguration.publicCode
                == "missing_configuration"
        )
        #expect(rejectedCredential.kind == .authentication)
        #expect(rejectedCredential.publicCode == "http_status_401")
    }

    @Test
    func synchronizationFailurePreservesChainSpecificDiagnostics() {
        let solanaFailure = WalletChainSyncFailure(
            source: .solana,
            stage: .providerRead,
            error: SolanaProviderError.primaryBalanceUnavailable
        )
        let bitcoinFailure = WalletChainSyncFailure(
            source: .bitcoinFamily,
            stage: .providerRead,
            error: BitcoinFamilySyncError.providersFailed(
                indexedAPI: "http_status=503",
                fallbackAPI: "timeout",
                electrum: "unavailable"
            )
        )

        #expect(
            solanaFailure.publicCode
                == "solana_primary_balance_unavailable"
        )
        #expect(
            bitcoinFailure.publicCode.contains(
                "indexed_api=(http_status=503)"
            )
        )
        #expect(
            bitcoinFailure.publicCode.contains(
                "fallback_api=(timeout)"
            )
        )
        #expect(
            bitcoinFailure.publicCode.contains(
                "electrum=(unavailable)"
            )
        )
    }

    @Test
    func bitcoinFamilyFailureNamesOnlyTheFailedNetwork() {
        let failure = WalletChainSyncFailure(
            source: .bitcoinFamily,
            stage: .providerRead,
            error: BitcoinFamilyAPIError.timeout,
            networkID: BitcoinFamilyChain.dogecoin.networkID
        )

        #expect(
            failure.localizedSourceName
                == WalletLocalization.string("network.dogecoin.name")
        )
        #expect(
            failure.localizedSourceName
                != WalletSyncSource.bitcoinFamily.localizedName
        )
    }

    @Test
    func zeroBalanceWalletWithActivityIsUsed() {
        #expect(
            WalletHomeUsagePolicy.isUsed(
                totalBalance: 0,
                hasStoredActivity: true
            )
        )
    }

    @Test
    func zeroBalanceWalletWithoutActivityIsEmpty() {
        #expect(
            !WalletHomeUsagePolicy.isUsed(
                totalBalance: 0,
                hasStoredActivity: false
            )
        )
    }

    @Test
    func positiveBalanceWalletWithoutActivityIsUsed() {
        #expect(
            WalletHomeUsagePolicy.isUsed(
                totalBalance: 1,
                hasStoredActivity: false
            )
        )
    }
}

struct FreshWalletHomeAssetTests {
    @Test
    func freshWalletDoesNotSynthesizeALocalCatalog() {
        let available = WalletHomeAssetCatalog.availableAssets(
            from: [],
            remoteCatalogAssets: []
        )

        #expect(available.isEmpty)
    }

    @Test
    func zeroBalanceWalletKeepsTheSameMainScreenCatalog() {
        let available = WalletHomeAssetCatalog.availableAssets(
            from: [],
            remoteCatalogAssets: []
        )
        let visible = WalletHomeAssetVisibility.homeAssets(
            from: available,
            transactions: [],
            walletAddress: "used-wallet",
            preferencesJSON: ""
        )

        let expected = WalletHomeAssetCatalog.mainScreenAssets(
            from: available
        )

        #expect(
            visible.map { AssetIdentityKey.canonical($0.id) }
                == expected.map { AssetIdentityKey.canonical($0.id) }
        )
    }

    @Test
    func positiveHoldingReplacesTheMainScreenCatalog() {
        let unrelatedHolding = WalletAsset(
            id: "solana:unrelated-mint",
            name: "Unrelated Token",
            symbol: "OTHER",
            logoSource: .unavailable,
            network: .solana,
            balance: 500,
            fiatValue: 10_000,
            decimals: 9
        )
        let available = WalletHomeAssetCatalog.availableAssets(
            from: [unrelatedHolding]
        )
        let visible = WalletHomeAssetVisibility.homeAssets(
            from: available,
            transactions: [],
            walletAddress: "used-wallet",
            preferencesJSON: ""
        )

        #expect(visible.map(\.id) == [unrelatedHolding.id])
    }

    @Test
    func fundedWalletShowsAtMostFifteenAssetsSortedByFiatValue() {
        let holdings = (0..<17).map { index in
            WalletAsset(
                id: "eth:token-\(index)",
                name: "Token \(index)",
                symbol: "T\(index)",
                logoSource: .unavailable,
                network: .ethereum,
                balance: 1,
                fiatValue: Decimal(index + 1)
            )
        }
        let available = WalletHomeAssetCatalog.availableAssets(
            from: holdings
        )
        let visible = WalletHomeAssetVisibility.homeAssets(
            from: available,
            transactions: [],
            walletAddress: "funded-wallet",
            preferencesJSON: ""
        )

        #expect(
            visible.count
                == WalletHomeAssetVisibility.maximumFundedHomeAssetCount
        )
        let expectedValues = (3...17).reversed().map { Decimal($0) }
        #expect(visible.map(\.fiatValue) == expectedValues)
        #expect(!visible.contains { $0.balance == 0 })
    }

    @Test
    func higherValueAutomaticHoldingDisplacesExplicitLowerValueAsset()
        throws
    {
        let lowerValueAssets = (0..<15).map { index in
            WalletAsset(
                id: "eth:lower-\(index)",
                name: "Lower \(index)",
                symbol: "LOW\(index)",
                logoSource: .unavailable,
                network: .ethereum,
                balance: 1,
                fiatValue: Decimal(index + 1)
            )
        }
        let usdt = WalletAsset(
            id: "eth:usdt",
            name: "Tether USD",
            symbol: "USDT",
            logoSource: .unavailable,
            network: .ethereum,
            balance: 200,
            fiatValue: 200
        )
        let preferences = try lowerValueAssets.reduce("{}") {
            preferences, asset in
            try #require(
                WalletHomeAssetVisibility.updatedPreferencesJSON(
                    setting: true,
                    for: asset,
                    walletAddress: "funded-wallet",
                    preferencesJSON: preferences
                )
            )
        }

        let visible = WalletHomeAssetVisibility.homeAssets(
            from: lowerValueAssets + [usdt],
            transactions: [],
            walletAddress: "funded-wallet",
            preferencesJSON: preferences
        )

        #expect(visible.count == 15)
        #expect(visible.first?.id == usdt.id)
        #expect(!visible.contains { $0.id == lowerValueAssets[0].id })
        #expect(
            visible.map(\.fiatValue)
                == visible.map(\.fiatValue).sorted(by: >)
        )
    }

    @Test
    func managementVisibilityDoesNotTreatTopFifteenCutoffAsUserHide() {
        let holdings = (0..<16).map { index in
            WalletAsset(
                id: "eth:holding-\(index)",
                name: "Holding \(index)",
                symbol: "H\(index)",
                logoSource: .unavailable,
                network: .ethereum,
                balance: 1,
                fiatValue: Decimal(index + 1)
            )
        }

        let homeAssets = WalletHomeAssetVisibility.homeAssets(
            from: holdings,
            transactions: [],
            walletAddress: "funded-wallet",
            preferencesJSON: ""
        )
        let managedVisibleIDs =
            WalletHomeAssetVisibility.managementVisibleAssetIDs(
                from: holdings,
                transactions: [],
                walletAddress: "funded-wallet",
                preferencesJSON: ""
            )

        #expect(homeAssets.count == 15)
        #expect(managedVisibleIDs.count == 16)
        #expect(
            managedVisibleIDs.isSuperset(
                of: homeAssets.map {
                    AssetIdentityKey.canonical($0.id)
                }
            )
        )
    }

    @Test
    func manuallyHiddenHoldingStaysHiddenUntilReenabledAndKeepsBalance()
        throws
    {
        let hidden = WalletAsset(
            id: "eth:hidden-usdt",
            name: "Tether USD",
            symbol: "USDT",
            logoSource: .unavailable,
            network: .ethereum,
            balance: 200,
            fiatValue: 200,
            balanceText: "200"
        )
        let fallback = WalletAsset(
            id: "eth:fallback",
            name: "Fallback",
            symbol: "BACK",
            logoSource: .unavailable,
            network: .ethereum,
            balance: 1,
            fiatValue: 1
        )
        let preferences = try #require(
            WalletHomeAssetVisibility.updatedPreferencesJSON(
                setting: false,
                for: hidden,
                walletAddress: "funded-wallet",
                preferencesJSON: ""
            )
        )

        let visible = WalletHomeAssetVisibility.homeAssets(
            from: [hidden, fallback],
            transactions: [],
            walletAddress: "funded-wallet",
            preferencesJSON: preferences
        )
        let managedVisibleIDs =
            WalletHomeAssetVisibility.managementVisibleAssetIDs(
                from: [hidden, fallback],
                transactions: [],
                walletAddress: "funded-wallet",
                preferencesJSON: preferences
            )

        #expect(visible.map(\.id) == [fallback.id])
        #expect(
            !managedVisibleIDs.contains(
                AssetIdentityKey.canonical(hidden.id)
            )
        )
        #expect(hidden.displayBalanceText == "200")
        #expect(hidden.fiatValue == 200)

        let reenabledPreferences = try #require(
            WalletHomeAssetVisibility.updatedPreferencesJSON(
                setting: true,
                for: hidden,
                walletAddress: "funded-wallet",
                preferencesJSON: preferences
            )
        )
        let reenabled = WalletHomeAssetVisibility.homeAssets(
            from: [hidden, fallback],
            transactions: [],
            walletAddress: "funded-wallet",
            preferencesJSON: reenabledPreferences
        )

        #expect(reenabled.first?.id == hidden.id)
        #expect(reenabled.first?.displayBalanceText == "200")
        #expect(reenabled.first?.fiatValue == 200)
    }

    @Test
    func explicitAssetIsKeptAlongsideFundedAssets() throws {
        let funded = WalletAsset(
            id: "eth:funded",
            name: "Funded",
            symbol: "FUND",
            logoSource: .unavailable,
            network: .ethereum,
            balance: 5,
            fiatValue: 50
        )
        let selectedForReceive = WalletAsset(
            id: "eth:selected",
            name: "Selected",
            symbol: "SELECT",
            logoSource: .unavailable,
            network: .ethereum,
            balance: 0,
            fiatValue: 0
        )
        let preferences = try #require(
            WalletHomeAssetVisibility.updatedPreferencesJSON(
                setting: true,
                for: selectedForReceive,
                walletAddress: "funded-wallet",
                preferencesJSON: ""
            )
        )
        let visible = WalletHomeAssetVisibility.homeAssets(
            from: [funded, selectedForReceive],
            transactions: [],
            walletAddress: "funded-wallet",
            preferencesJSON: preferences
        )

        #expect(visible.map(\.id) == [funded.id, selectedForReceive.id])
    }

    @Test
    func hiddenFundedAssetDoesNotAppear() throws {
        let visibleHolding = WalletAsset(
            id: "eth:visible",
            name: "Visible",
            symbol: "SHOW",
            logoSource: .unavailable,
            network: .ethereum,
            balance: 2,
            fiatValue: 20
        )
        let hiddenHolding = WalletAsset(
            id: "eth:hidden",
            name: "Hidden",
            symbol: "HIDE",
            logoSource: .unavailable,
            network: .ethereum,
            balance: 3,
            fiatValue: 30
        )
        let preferences = try #require(
            WalletHomeAssetVisibility.updatedPreferencesJSON(
                setting: false,
                for: hiddenHolding,
                walletAddress: "funded-wallet",
                preferencesJSON: ""
            )
        )
        let visible = WalletHomeAssetVisibility.homeAssets(
            from: [visibleHolding, hiddenHolding],
            transactions: [],
            walletAddress: "funded-wallet",
            preferencesJSON: preferences
        )

        #expect(visible.map(\.id) == [visibleHolding.id])
    }

    @Test
    func pinningAssetMovesItToFrontAndIsScopedToWallet() throws {
        let higherValueAsset = WalletAsset(
            id: "eth:higher-value",
            name: "Higher Value",
            symbol: "HIGH",
            logoSource: .unavailable,
            network: .ethereum,
            balance: 10,
            fiatValue: 100
        )
        let pinnedAsset = WalletAsset(
            id: "eth:pinned",
            name: "Pinned",
            symbol: "PIN",
            logoSource: .unavailable,
            network: .ethereum,
            balance: 1,
            fiatValue: 1
        )
        let preferences = try #require(
            WalletHomeAssetVisibility.updatedPreferencesJSON(
                settingPinned: true,
                for: pinnedAsset,
                walletAddress: "first-wallet",
                preferencesJSON: ""
            )
        )

        let visible = WalletHomeAssetVisibility.homeAssets(
            from: [higherValueAsset, pinnedAsset],
            transactions: [],
            walletAddress: "first-wallet",
            preferencesJSON: preferences
        )

        #expect(visible.map(\.id) == [pinnedAsset.id, higherValueAsset.id])
        #expect(
            WalletHomeAssetVisibility.isPinned(
                pinnedAsset,
                walletAddress: "first-wallet",
                preferencesJSON: preferences
            )
        )
        #expect(
            !WalletHomeAssetVisibility.isPinned(
                pinnedAsset,
                walletAddress: "second-wallet",
                preferencesJSON: preferences
            )
        )
    }

    @Test
    func unpinningAssetRestoresValueOrdering() throws {
        let higherValueAsset = WalletAsset(
            id: "eth:higher-value",
            name: "Higher Value",
            symbol: "HIGH",
            logoSource: .unavailable,
            network: .ethereum,
            balance: 10,
            fiatValue: 100
        )
        let formerlyPinnedAsset = WalletAsset(
            id: "eth:formerly-pinned",
            name: "Formerly Pinned",
            symbol: "OLDPIN",
            logoSource: .unavailable,
            network: .ethereum,
            balance: 1,
            fiatValue: 1,
            isPinned: true
        )
        let preferences = try #require(
            WalletHomeAssetVisibility.updatedPreferencesJSON(
                settingPinned: false,
                for: formerlyPinnedAsset,
                walletAddress: "wallet",
                preferencesJSON: ""
            )
        )
        let visible = WalletHomeAssetVisibility.homeAssets(
            from: [formerlyPinnedAsset, higherValueAsset],
            transactions: [],
            walletAddress: "wallet",
            preferencesJSON: preferences
        )

        #expect(
            !WalletHomeAssetVisibility.isPinned(
                formerlyPinnedAsset,
                walletAddress: "wallet",
                preferencesJSON: preferences
            )
        )
        #expect(
            visible.map(\.id)
                == [higherValueAsset.id, formerlyPinnedAsset.id]
        )
    }

    @Test
    func hidingPinnedAssetUnpinsUntilManageAssetsReenablesIt() throws {
        let asset = WalletAsset(
            id: "eth:pinned-then-hidden",
            name: "Pinned Then Hidden",
            symbol: "PTH",
            logoSource: .unavailable,
            network: .ethereum,
            balance: 5,
            fiatValue: 50
        )
        let pinnedPreferences = try #require(
            WalletHomeAssetVisibility.updatedPreferencesJSON(
                settingPinned: true,
                for: asset,
                walletAddress: "wallet",
                preferencesJSON: ""
            )
        )
        let hiddenPreferences = try #require(
            WalletHomeAssetVisibility.updatedPreferencesJSON(
                setting: false,
                for: asset,
                walletAddress: "wallet",
                preferencesJSON: pinnedPreferences
            )
        )

        #expect(
            WalletHomeAssetVisibility.homeAssets(
                from: [asset],
                transactions: [],
                walletAddress: "wallet",
                preferencesJSON: hiddenPreferences
            ).isEmpty
        )
        #expect(
            !WalletHomeAssetVisibility.managementVisibleAssetIDs(
                from: [asset],
                transactions: [],
                walletAddress: "wallet",
                preferencesJSON: hiddenPreferences
            ).contains(AssetIdentityKey.canonical(asset.id))
        )
        #expect(
            !WalletHomeAssetVisibility.isPinned(
                asset,
                walletAddress: "wallet",
                preferencesJSON: hiddenPreferences
            )
        )

        let reenabledPreferences = try #require(
            WalletHomeAssetVisibility.updatedPreferencesJSON(
                setting: true,
                for: asset,
                walletAddress: "wallet",
                preferencesJSON: hiddenPreferences
            )
        )

        #expect(
            WalletHomeAssetVisibility.homeAssets(
                from: [asset],
                transactions: [],
                walletAddress: "wallet",
                preferencesJSON: reenabledPreferences
            ).map(\.id) == [asset.id]
        )
        #expect(
            !WalletHomeAssetVisibility.isPinned(
                asset,
                walletAddress: "wallet",
                preferencesJSON: reenabledPreferences
            )
        )
    }
}

struct WalletNetworkSelectionOrderingTests {
    @Test
    func positiveLocalValueRanksBeforeTransactionActivity() {
        let ordering = WalletNetworkSelectionOrdering(
            localCurrencyValueByNetworkID: [
                "eth": 125,
                "polygon": 300
            ],
            transactionCountByNetworkID: [
                "eth": 2,
                "polygon": 1,
                "tron": 500
            ]
        )

        let result = ordering.ordered(
            ["eth", "tron", "solana", "polygon", "bsc"],
            networkID: { $0 }
        )

        #expect(
            result
                == ["polygon", "eth", "tron", "solana", "bsc"]
        )
    }

    @Test
    func zeroValueNetworksRankByActivityThenKeepCatalogOrder() {
        let ordering = WalletNetworkSelectionOrdering(
            localCurrencyValueByNetworkID: [:],
            transactionCountByNetworkID: [
                "tron": 4,
                "solana": 11
            ]
        )

        let result = ordering.ordered(
            ["eth", "tron", "solana", "bsc", "polygon"],
            networkID: { $0 }
        )

        #expect(
            result
                == ["solana", "tron", "eth", "bsc", "polygon"]
        )
    }

    @Test
    func providerAliasesUseTheCanonicalPickerNetwork() {
        let ordering = WalletNetworkSelectionOrdering(
            localCurrencyValueByNetworkID: [
                "ethereum": 10,
                "doge": 20,
                "bitcoincash": 30
            ],
            transactionCountByNetworkID: [:]
        )

        let result = ordering.ordered(
            ["eth", "dogecoin", "bitcoin_cash", "bitcoin"],
            networkID: { $0 }
        )

        #expect(
            result
                == ["bitcoin_cash", "dogecoin", "eth", "bitcoin"]
        )
    }
}

struct WalletTransactionAmountFormattingTests {
    @Test
    func exactTransactionAmountIsRoundedToEightFractionDigits() {
        let transaction = makeTransaction(
            amount: "-114.991526908307368"
        )

        #expect(transaction.displayAssetAmountText == "-114.99152691")
    }

    @Test
    func incomingTransactionKeepsItsPositiveSignAfterRounding() {
        let transaction = makeTransaction(
            amount: "0.123456789"
        )

        #expect(transaction.displayAssetAmountText == "+0.12345679")
    }

    @Test
    func roundingCarriesAcrossTheIntegerBoundary() {
        let transaction = makeTransaction(
            amount: "999.999999999"
        )

        #expect(transaction.displayAssetAmountText == "+1000")
    }

    @Test
    func valuesAtOrBelowEightFractionDigitsRemainUnchanged() {
        let transaction = makeTransaction(
            amount: "-42.12345678"
        )

        #expect(transaction.displayAssetAmountText == "-42.12345678")
    }

    @Test
    func fullExactAmountRemainsStoredAfterDisplayRounding() {
        let exactAmount = "-114.991526908307368"
        let transaction = makeTransaction(amount: exactAmount)

        #expect(transaction.assetAmountText == exactAmount)
        #expect(transaction.displayAssetAmountText != exactAmount)
    }

    private func makeTransaction(
        amount: String
    ) -> WalletTransaction {
        WalletTransaction(
            id: UUID().uuidString,
            kind: amount.hasPrefix("-")
                ? .sent(assetSymbol: "POL")
                : .received(assetSymbol: "POL"),
            detail: "",
            time: "",
            assetLogoSource: .nativeCoin(blockchain: .polygon),
            assetAmount: Decimal(
                string: amount,
                locale: Locale(identifier: "en_US_POSIX")
            ) ?? 0,
            assetAmountText: amount,
            assetSymbol: "POL",
            fiatValue: nil,
            status: .confirmed
        )
    }
}

struct WalletTransactionDayFormattingTests {
    @Test
    func activityRowsShowOnlyRelativeDayOrCalendarDate() throws {
        let calendar = gregorianCalendar
        let now = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 7,
                    day: 29,
                    hour: 12
                )
            )
        )
        let today = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 7,
                    day: 29,
                    hour: 20,
                    minute: 31
                )
            )
        )
        let yesterday = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 7,
                    day: 28,
                    hour: 20,
                    minute: 31
                )
            )
        )
        let older = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 7,
                    day: 27,
                    hour: 3,
                    minute: 54
                )
            )
        )

        #expect(
            EnglishNumbers.walletActivityDay(
                today,
                relativeTo: now
            ) == WalletLocalization.string(
                "wallet.activity.day.today"
            )
        )
        #expect(
            EnglishNumbers.walletActivityDay(
                yesterday,
                relativeTo: now
            ) == WalletLocalization.string(
                "wallet.activity.day.yesterday"
            )
        )
        #expect(
            EnglishNumbers.walletActivityDay(
                older,
                relativeTo: now
            ) == "2026-07-27"
        )
    }

    @Test
    func notificationTimestampRetainsItsTime() throws {
        let calendar = gregorianCalendar
        let now = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 7,
                    day: 29,
                    hour: 12
                )
            )
        )
        let yesterday = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 7,
                    day: 28,
                    hour: 20,
                    minute: 31
                )
            )
        )

        #expect(
            EnglishNumbers.walletTimestamp(
                yesterday,
                relativeTo: now
            ) == EnglishNumbers.localized(
                "wallet.activity.time.yesterday",
                "8:31 PM"
            )
        )
    }

    private var gregorianCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }
}

import Foundation
import Testing
@testable import Aperture

@Suite(.serialized)
struct WalletActionPresentationPerformanceTests {
    @Test
    func presentationBudgetsRejectRegressions() {
        let budgets:
            [(WalletActionPresentationPerformanceMetric, Double)] = [
                (
                    .firstFrame,
                    WalletActionPresentationPerformanceBudget
                        .maximumFirstFrameMilliseconds
                ),
                (
                    .mainQueueTurn,
                    WalletActionPresentationPerformanceBudget
                        .maximumMainQueueTurnMilliseconds
                ),
                (
                    .destinationInitialization,
                    WalletActionPresentationPerformanceBudget
                        .maximumDestinationInitializationMilliseconds
                ),
                (
                    .cpuPreparation,
                    WalletActionPresentationPerformanceBudget
                        .maximumCPUPreparationMilliseconds
                ),
                (
                    .indexedLookup,
                    WalletActionPresentationPerformanceBudget
                        .maximumIndexedLookupMilliseconds
                ),
                (
                    .preparationCount,
                    Double(
                        WalletActionPresentationPerformanceBudget
                            .maximumPreparationsPerBurst
                    )
                )
            ]

        for (metric, limit) in budgets {
            #expect(
                !WalletActionPresentationPerformanceBudget.exceedsLimit(
                    metric: metric,
                    value: limit
                )
            )
            #expect(
                WalletActionPresentationPerformanceBudget.exceedsLimit(
                    metric: metric,
                    value: limit + 0.001
                )
            )
        }
    }

    @Test
    func preparationBurstCountIsRevisionScopedAndWindowed() {
        var counter = WalletActionPreparationBurstCounter()
        let firstRequest = UUID()
        let secondRequest = UUID()
        let window =
            WalletActionPresentationPerformanceBudget
            .preparationBurstNanoseconds

        #expect(counter.record(requestID: firstRequest, at: 0) == 1)
        #expect(
            counter.record(
                requestID: firstRequest,
                at: window / 2
            ) == 2
        )
        #expect(
            counter.record(
                requestID: firstRequest,
                at: window / 2 + 1
            ) == 3
        )
        #expect(
            WalletActionPresentationPerformanceBudget.exceedsLimit(
                metric: .preparationCount,
                value: 3
            )
        )
        #expect(
            counter.record(
                requestID: firstRequest,
                at: window * 2
            ) == 1
        )
        #expect(counter.record(requestID: secondRequest, at: 0) == 1)
    }

    @Test
    func progressiveChainSnapshotsDoNotRebuildActionIndexes() {
        #expect(
            WalletActionPreparationPublicationStage
                .immediateState
                .schedulesPreparation
        )
        #expect(
            !WalletActionPreparationPublicationStage
                .progressiveChainSnapshot
                .schedulesPreparation
        )
        #expect(
            WalletActionPreparationPublicationStage
                .synchronizedAggregate
                .schedulesPreparation
        )
    }

    @Test
    func populatedCatalogPreparationStaysInsideCPUBudget() async throws {
        _ = try WalletDatabase.temporary()
        let previousCatalog = WalletPerformanceCatalogFixture.install()
        defer { WalletPerformanceCatalogFixture.restore(previousCatalog) }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let preparation =
            await WalletActionPresentationPreparationBuilder.make(
                snapshot: .empty,
                capabilities: .fullWallet,
                walletAddress:
                    "0x1111111111111111111111111111111111111111",
                visibilityPreferencesJSON: "{}"
            )
        let elapsedMilliseconds = milliseconds(since: startedAt)

        #expect(!preparation.flowAssets.isEmpty)
        #expect(!preparation.send.initialSelections.isEmpty)
        #expect(!preparation.assetLists.initialBrowseSections.isEmpty)
        #expect(!preparation.assetLists.initialManageGroups.isEmpty)
        #expect(
            elapsedMilliseconds
                <= WalletActionPresentationPerformanceBudget
                    .maximumCPUPreparationMilliseconds
        )
    }

    @Test
    func populatedCatalogQueriesUseThePreparedIndexBudget() async {
        let previousCatalog = WalletPerformanceCatalogFixture.install()
        defer { WalletPerformanceCatalogFixture.restore(previousCatalog) }
        ReceiveAssetSearchIndex.prepare()
        let preparation =
            await WalletActionPresentationPreparationBuilder.make(
                snapshot: .empty,
                capabilities: .fullWallet,
                walletAddress:
                    "0x1111111111111111111111111111111111111111",
                visibilityPreferencesJSON: "{}"
            )

        _ = ReceiveAssetSearchIndex.candidates(
            networkID: "eth",
            matching: "USDT Ethereum"
        )
        _ = preparation.receive.discoveryIndex.selections(
            networkID: "eth",
            searchText: ""
        )

        let lookupCount = 100
        let startedAt = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<lookupCount {
            let catalogMatches =
                ReceiveAssetSearchIndex.candidates(
                    networkID: "eth",
                    matching: "USDT Ethereum"
                )
            let networkSelections =
                preparation.receive.discoveryIndex.selections(
                    networkID: "eth",
                    searchText: ""
                )
            #expect(!catalogMatches.isEmpty)
            #expect(!networkSelections.isEmpty)
        }
        let averageMilliseconds =
            milliseconds(since: startedAt) / Double(lookupCount)

        #expect(
            averageMilliseconds
                <= WalletActionPresentationPerformanceBudget
                    .maximumIndexedLookupMilliseconds
        )
    }

    @Test
    func preparedSendAndReceiveRowsHaveOneEntryPerAssetIdentity()
        async throws
    {
        let credential = try WalletRecoveryCredential(
            mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        )
        let wallet = try WalletCoreService.importRecoveryPhrase(
            credential.mnemonic,
            passphrase: credential.passphrase
        )
        let persistedAccounts = try WalletAccountDerivationService
            .deriveFullWallet(
                credential: credential,
                expectedEVMAddress: wallet.address,
                expectedEVMPublicKey: wallet.publicKey
            )
        let accountAddresses = WalletAccountAddressIndex(
            records: persistedAccounts.map {
                $0.record(walletID: "performance-test", now: 1)
            }
        )
        let holdings = [
            nativeHolding(
                id: "tron:native",
                name: "TRON",
                symbol: "TRX",
                blockchain: .tron,
                fiatValue: 30
            ),
            nativeHolding(
                id: AptosConstants.nativeAssetID,
                name: "Aptos",
                symbol: AptosConstants.nativeSymbol,
                blockchain: .aptos,
                fiatValue: 20
            ),
            nativeHolding(
                id: SuiConstants.nativeAssetID,
                name: "Sui",
                symbol: SuiConstants.nativeSymbol,
                blockchain: .sui,
                fiatValue: 10
            ),
            nativeHolding(
                id: TONConstants.nativeAssetID,
                name: "Gram",
                symbol: TONConstants.nativeSymbol,
                blockchain: .ton,
                fiatValue: 5
            )
        ]
        let preparation =
            await WalletActionPresentationPreparationBuilder.make(
                snapshot: WalletHomeSnapshot(
                    totalBalance: 65,
                    assets: holdings,
                    transactions: []
                ),
                capabilities: .fullWallet,
                walletAddress:
                    "0x1111111111111111111111111111111111111111",
                visibilityPreferencesJSON: "{}",
                accountAddresses: accountAddresses
            )

        for selections in [
            preparation.receive.initialSelections,
            preparation.send.initialSelections
        ] {
            expectUniqueRows(selections, holdings: holdings)
        }

        let index = preparation.receive.discoveryIndex
        expectUniqueRows(
            index.selections(networkID: nil, searchText: ""),
            holdings: holdings
        )
        for option in AssetNetworkSelectorOption.allSupported {
            let selections = index.selections(
                networkID: option.id,
                searchText: ""
            )
            let identities = selections.map(\.canonicalAssetIdentity)
            #expect(identities.count == Set(identities).count)
        }
        for query in ["TRON", "Aptos", "Sui", "Gram"] {
            let selections = index.selections(
                networkID: nil,
                searchText: query
            )
            let identities = selections.map(\.canonicalAssetIdentity)
            #expect(identities.count == Set(identities).count)
        }
    }

    @Test
    func initialMainThreadWindowStaysBoundedAtProductionScale() {
        let totalCount = 2_874
        let initialCount = AssetListRenderingWindow.initialCount(
            for: totalCount
        )

        #expect(initialCount == 18)
        #expect(initialCount < totalCount)
        #expect(
            initialCount
                <= AssetListRenderingWindow.initialRowCount
        )
    }

    @Test
    @MainActor
    func scannerToSendTransitionKeepsOneAtomicPresentation() async {
        let context = AppRootResolvedWalletContext(
            requestID: UUID(),
            identity: PersistedWalletIdentity(
                walletID: "wallet-performance-test",
                address:
                    "0x1111111111111111111111111111111111111111"
            ),
            name: "Wallet",
            capabilities: .fullWallet
        )
        let preparation =
            await WalletActionPresentationPreparationBuilder.make(
                snapshot: .empty,
                capabilities: context.capabilities,
                walletAddress: context.identity.address,
                visibilityPreferencesJSON: "{}"
            )
        let scanner = WalletScannerPresentationPayload(
            walletAddress: context.identity.address,
            capabilities: context.capabilities,
            walletAssets: preparation.flowAssets,
            transactions: preparation.transactions,
            sendPreparation: preparation.send,
            contentRevision: UUID()
        )
        let presentation = WalletActionPresentation(
            context: context,
            initialDestination: .scanner(scanner)
        )
        let send = WalletSendPresentationPayload(
            walletAddress: context.identity.address,
            capabilities: context.capabilities,
            walletAssets: preparation.flowAssets,
            transactions: preparation.transactions,
            preparation: preparation.send,
            initialRoute: nil,
            contentRevision: UUID()
        )
        let nextDestination = WalletActionSheetDestination.send(send)

        #expect(presentation.context == context)
        #expect(
            presentation.initialDestination.coveringModalID
                == .scanner
        )
        #expect(nextDestination.id == send.id)
        #expect(nextDestination.coveringModalID == .send)
    }

    @Test
    @MainActor
    func preparedHomeActionCreatesAnImmediateAtomicRoute() async {
        let context = AppRootResolvedWalletContext(
            requestID: UUID(),
            identity: PersistedWalletIdentity(
                walletID: "wallet-cold-action-test",
                address:
                    "0x1111111111111111111111111111111111111111"
            ),
            name: "Wallet",
            capabilities: .fullWallet
        )
        let preparation =
            await WalletActionPresentationPreparationBuilder.make(
                snapshot: .empty,
                capabilities: context.capabilities,
                walletAddress: context.identity.address,
                visibilityPreferencesJSON: "{}"
            )
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let payload = WalletSendPresentationPayload(
            walletAddress: context.identity.address,
            capabilities: context.capabilities,
            walletAssets: preparation.flowAssets,
            transactions: preparation.transactions,
            preparation: preparation.send,
            initialRoute: nil,
            contentRevision: UUID()
        )
        let presentation = WalletActionPresentation(
            context: context,
            initialDestination: .send(payload)
        )
        let elapsedMilliseconds = milliseconds(since: startedAt)

        #expect(presentation.context == context)
        #expect(
            presentation.initialDestination.coveringModalID
                == .send
        )
        #expect(
            elapsedMilliseconds
                <= WalletActionPresentationPerformanceBudget
                    .maximumImmediateCommitMilliseconds
        )
    }

    @Test
    func splashReadinessRejectsAStalePreparation() {
        #expect(
            WalletActionReadinessRequirement
                .presentationSafe
                .isSatisfied(
                    hasCurrentPreparation: false,
                    hasStablePreparation: true
                )
        )
        #expect(
            !WalletActionReadinessRequirement
                .currentSnapshot
                .isSatisfied(
                    hasCurrentPreparation: false,
                    hasStablePreparation: true
                )
        )
        #expect(
            WalletActionReadinessRequirement
                .currentSnapshot
                .isSatisfied(
                    hasCurrentPreparation: true,
                    hasStablePreparation: false
                )
        )
    }

    @Test
    func contentRefreshKeepsSameWalletPreparationPresentationSafe() async {
        let context = AppRootResolvedWalletContext(
            requestID: UUID(),
            identity: PersistedWalletIdentity(
                walletID: "wallet-refresh-presentation-test",
                address:
                    "0x1111111111111111111111111111111111111111"
            ),
            name: "Wallet",
            capabilities: .fullWallet
        )
        let originalRevision = UUID()
        let refreshedRevision = UUID()
        let cpuPreparation =
            await WalletActionPresentationPreparationBuilder.make(
                snapshot: .empty,
                capabilities: context.capabilities,
                walletAddress: context.identity.address,
                visibilityPreferencesJSON: "{}"
            )
        let preparation = WalletActionPresentationPreparation(
            requestID: context.requestID,
            identity: context.identity,
            capabilities: context.capabilities,
            source: .content,
            visibilityPreferencesJSON: "{}",
            stateRevision: originalRevision,
            home: cpuPreparation.home,
            assetLists: cpuPreparation.assetLists,
            flowAssets: cpuPreparation.flowAssets,
            transactions: cpuPreparation.transactions,
            receive: cpuPreparation.receive,
            send: cpuPreparation.send,
            directSingleCoinAsset:
                cpuPreparation.directSingleCoinAsset,
            bitcoinFamilyAsset: nil
        )
        let refreshedPresentation = AppRootWalletPresentation.resolved(
            context: context,
            state: .content(.empty),
            stateRevision: refreshedRevision
        )

        #expect(
            !preparation.matchesActionPresentation(
                presentation: refreshedPresentation,
                visibilityPreferencesJSON: "{}"
            )
        )
        #expect(
            preparation.matchesHomeDisplay(
                presentation: refreshedPresentation,
                visibilityPreferencesJSON: "{}"
            )
        )
        #expect(
            !preparation.matchesHomeDisplay(
                presentation: refreshedPresentation,
                visibilityPreferencesJSON: "{\"changed\":true}"
            )
        )
        #expect(
            preparation.matchesStableActionPresentation(
                presentation: refreshedPresentation,
                visibilityPreferencesJSON: "{}"
            )
        )
        #expect(
            !preparation.matchesHomeDisplay(
                presentation: .resolved(
                    context: context.replacingRequestID(UUID()),
                    state: .content(.empty),
                    stateRevision: refreshedRevision
                ),
                visibilityPreferencesJSON: "{}"
            )
        )
        #expect(
            !preparation.matchesStableActionPresentation(
                presentation: .resolved(
                    context: context.replacingRequestID(UUID()),
                    state: .content(.empty),
                    stateRevision: refreshedRevision
                ),
                visibilityPreferencesJSON: "{}"
            )
        )
        #expect(
            !preparation.matchesStableActionPresentation(
                presentation: .resolved(
                    context: context,
                    state: .loading,
                    stateRevision: refreshedRevision
                ),
                visibilityPreferencesJSON: "{}"
            )
        )
    }

    @Test
    func scrollVisibilityReportsOnlyBooleanEdges() {
        var visibility = WalletHomeTrackedVisibility()
        let firstBalanceVisible = visibility.recordBalance(true)
        let repeatedBalanceVisible = visibility.recordBalance(true)
        let firstBalanceHidden = visibility.recordBalance(false)
        let repeatedBalanceHidden = visibility.recordBalance(false)
        let firstActionsVisible = visibility.recordActions(true)
        let repeatedActionsVisible = visibility.recordActions(true)
        let firstActionsHidden = visibility.recordActions(false)
        let repeatedActionsHidden = visibility.recordActions(false)

        #expect(firstBalanceVisible)
        #expect(!repeatedBalanceVisible)
        #expect(firstBalanceHidden)
        #expect(!repeatedBalanceHidden)
        #expect(firstActionsVisible)
        #expect(!repeatedActionsVisible)
        #expect(firstActionsHidden)
        #expect(!repeatedActionsHidden)
    }

    @Test
    func scrollVisibilityUsesMeasuredRowThresholds() {
        var thresholds = WalletHomeScrollVisibilityThresholds()
        #expect(
            WalletHomeScrollVisibilityPolicy.visibility(
                contentOffsetY: 1_000,
                contentInsetTop: 0,
                thresholds: thresholds
            ) == .allVisible
        )

        thresholds.recordBalanceHeight(120.2)
        thresholds.recordActionsHeight(79.8)

        #expect(
            WalletHomeScrollVisibilityPolicy.visibility(
                contentOffsetY: 119,
                contentInsetTop: 0,
                thresholds: thresholds
            ) == WalletHomeScrollVisibility(
                balance: true,
                actions: true
            )
        )
        #expect(
            WalletHomeScrollVisibilityPolicy.visibility(
                contentOffsetY: 120,
                contentInsetTop: 0,
                thresholds: thresholds
            ) == WalletHomeScrollVisibility(
                balance: false,
                actions: true
            )
        )
        #expect(
            WalletHomeScrollVisibilityPolicy.visibility(
                contentOffsetY: 200,
                contentInsetTop: 0,
                thresholds: thresholds
            ) == WalletHomeScrollVisibility(
                balance: false,
                actions: false
            )
        )
        #expect(thresholds.balanceHeight == 120)
        #expect(thresholds.actionsHeight == 80)
    }

    @Test
    func preparedHomeProjectionUsesCurrentValuesAndAddsNewAssets() {
        let prepared = nativeHolding(
            id: "tron:native",
            name: "TRON",
            symbol: "TRX",
            blockchain: .tron,
            fiatValue: 1
        )
        let refreshed = nativeHolding(
            id: "tron:native",
            name: "TRON",
            symbol: "TRX",
            blockchain: .tron,
            fiatValue: 25
        )
        let newlyFunded = nativeHolding(
            id: AptosConstants.nativeAssetID,
            name: "Aptos",
            symbol: AptosConstants.nativeSymbol,
            blockchain: .aptos,
            fiatValue: 10
        )

        let projected = WalletHomePreparedAssetProjection.candidates(
            preparedVisibleAssets: [prepared],
            currentAssets: [refreshed, newlyFunded]
        )

        #expect(projected.count == 2)
        #expect(projected[0].id == refreshed.id)
        #expect(projected[0].fiatValue == 25)
        #expect(projected[1].id == newlyFunded.id)
    }

    @Test
    func portfolioVisibilityUsesOneReusablePreferenceResolution() {
        let walletAddress = "0xABC"
        let asset = nativeHolding(
            id: "tron:native",
            name: "TRON",
            symbol: "TRX",
            blockchain: .tron,
            fiatValue: 1
        )
        let json = """
        {
          "wallets": {"0xabc": {"tron:native": true}},
          "pinnedWallets": {"0xabc": {"tron:native": true}}
        }
        """
        let resolution = WalletHomeAssetVisibility.resolution(
            walletAddress: walletAddress,
            preferencesJSON: json
        )

        #expect(resolution.visibilityOverride(for: asset) == true)
        #expect(resolution.isPinned(asset))
        #expect(
            WalletHomeAssetVisibility.homeAssets(
                from: [asset],
                transactions: [],
                resolution: resolution
            ).map(\.id) == [asset.id]
        )
    }

    @Test
    func equalProgressiveContentPreservesPresentationRevision() {
        let asset = nativeHolding(
            id: "tron:native",
            name: "TRON",
            symbol: "TRX",
            blockchain: .tron,
            fiatValue: 1
        )
        let snapshot = WalletHomeSnapshot(
            totalBalance: 1,
            assets: [asset],
            transactions: []
        )
        let changedSnapshot = WalletHomeSnapshot(
            totalBalance: 2,
            assets: [asset],
            transactions: []
        )

        #expect(
            !WalletPresentationStateRevisionPolicy.requiresReplacement(
                current: .content(snapshot),
                incoming: .content(snapshot)
            )
        )
        #expect(
            WalletPresentationStateRevisionPolicy.requiresReplacement(
                current: .content(snapshot),
                incoming: .content(changedSnapshot)
            )
        )
        #expect(
            WalletPresentationStateRevisionPolicy.requiresReplacement(
                current: .loading,
                incoming: .content(snapshot)
            )
        )
    }

    @Test
    func universalSearchSkipsAssetIndexWorkWhileClosed() {
        var evaluatedCandidates = false
        func candidates() -> [String] {
            evaluatedCandidates = true
            return ["tron:native"]
        }

        #expect(
            !WalletUniversalSearchWorkPolicy.shouldBuildIndex(
                isPresented: false
            )
        )
        let closedIDs = WalletUniversalSearchWorkPolicy.observedAssetIDs(
            isPresented: false,
            candidateAssetIDs: candidates()
        )
        #expect(closedIDs.isEmpty)
        #expect(!evaluatedCandidates)

        let openIDs = WalletUniversalSearchWorkPolicy.observedAssetIDs(
            isPresented: true,
            candidateAssetIDs: candidates()
        )
        #expect(openIDs == ["tron:native"])
        #expect(evaluatedCandidates)
    }

    @Test
    @MainActor
    func completedSyncPublishesOneAtomicProgressEvent() async {
        var events: [WalletSyncProgressEvent] = []

        await publishWalletSyncDatasets(
            source: .near,
            networkID: "near"
        ) { event in
            events.append(event)
        }

        #expect(events.count == 1)
        #expect(events.first?.stage == .snapshotPersisted)
        #expect(
            events.first?.stage.publicationScope
                == .portfolioAndActivity
        )
    }

    @Test
    func presentationAuthorizationAllowsTransientInactiveScene() {
        let context = AppRootResolvedWalletContext(
            requestID: UUID(),
            identity: PersistedWalletIdentity(
                walletID: "wallet-authorization-test",
                address:
                    "0x1111111111111111111111111111111111111111"
            ),
            name: "Wallet",
            capabilities: .fullWallet
        )
        let presentation = AppRootWalletPresentation.resolved(
            context: context,
            state: .content(.empty)
        )

        #expect(
            WalletActionPresentationAuthorization.allows(
                phase: .wallet,
                scenePhase: .active,
                isWalletAccessRestricted: false,
                presentation: presentation,
                context: context
            )
        )
        #expect(
            !WalletActionPresentationAuthorization.allows(
                phase: .launchAuthentication(
                    context.identity,
                    .secureDefault
                ),
                scenePhase: .active,
                isWalletAccessRestricted: false,
                presentation: presentation,
                context: context
            )
        )
        #expect(
            !WalletActionPresentationAuthorization.allows(
                phase: .wallet,
                scenePhase: .active,
                isWalletAccessRestricted: true,
                presentation: presentation,
                context: context
            )
        )
        #expect(
            !WalletActionPresentationAuthorization.allows(
                phase: .wallet,
                scenePhase: .inactive,
                isWalletAccessRestricted: true,
                presentation: presentation,
                context: context
            )
        )
        #expect(
            WalletActionPresentationAuthorization.allows(
                phase: .wallet,
                scenePhase: .inactive,
                isWalletAccessRestricted: false,
                presentation: presentation,
                context: context
            )
        )
        #expect(
            !WalletActionPresentationAuthorization.allows(
                phase: .wallet,
                scenePhase: .background,
                isWalletAccessRestricted: false,
                presentation: presentation,
                context: context
            )
        )
        #expect(
            !WalletActionPresentationAuthorization.allows(
                phase: .wallet,
                scenePhase: .active,
                isWalletAccessRestricted: false,
                presentation: presentation,
                context: context.replacingRequestID(UUID())
            )
        )
    }

    @Test
    func authenticatedRefreshWaitsForMatchingRenderedHomeFrame() {
        let identity = PersistedWalletIdentity(
            walletID: "secure-launch-wallet",
            address:
                "0x1111111111111111111111111111111111111111"
        )
        let requestID = UUID()
        var handoff = PostAuthenticationWalletRefreshHandoff()

        handoff.stage(
            requestID: requestID,
            identity: identity
        )

        let didConsumeMismatchedRequest =
            handoff.consumeAfterFirstRenderedFrame(
                requestID: UUID(),
                identity: identity
            )
        #expect(
            !didConsumeMismatchedRequest
        )
        #expect(handoff.pendingRequest == nil)
    }

    @Test
    func authenticatedRefreshHandoffIsMatchingAndSingleUse() {
        let identity = PersistedWalletIdentity(
            walletID: "secure-launch-wallet",
            address:
                "0x1111111111111111111111111111111111111111"
        )
        let requestID = UUID()
        var handoff = PostAuthenticationWalletRefreshHandoff()

        handoff.stage(
            requestID: requestID,
            identity: identity
        )

        let didConsumeMatchingRequest =
            handoff.consumeAfterFirstRenderedFrame(
                requestID: requestID,
                identity: identity
            )
        #expect(
            didConsumeMatchingRequest
        )
        let didConsumeRequestAgain =
            handoff.consumeAfterFirstRenderedFrame(
                requestID: requestID,
                identity: identity
            )
        #expect(
            !didConsumeRequestAgain
        )
    }

    private func milliseconds(
        since startedAtNanoseconds: UInt64
    ) -> Double {
        let current = DispatchTime.now().uptimeNanoseconds
        return Double(current - startedAtNanoseconds) / 1_000_000
    }

    private func nativeHolding(
        id: String,
        name: String,
        symbol: String,
        blockchain: WalletBlockchain,
        fiatValue: Decimal
    ) -> WalletAsset {
        WalletAsset(
            id: id,
            name: name,
            symbol: symbol,
            logoSource: .nativeCoin(blockchain: blockchain),
            network: blockchain,
            balance: 1,
            fiatValue: fiatValue,
            balanceText: "1",
            receiveAddress: "receive-\(id)"
        )
    }

    private func expectUniqueRows(
        _ selections: [AssetDiscoverySelection],
        holdings: [WalletAsset]
    ) {
        let identities = selections.map(\.canonicalAssetIdentity)
        #expect(identities.count == Set(identities).count)
        for holding in holdings {
            let identity = AssetIdentityKey.canonical(holding.id)
            #expect(
                identities.filter { $0 == identity }.count == 1,
                "Duplicate row for \(identity)"
            )
            #expect(
                selections.first {
                    $0.canonicalAssetIdentity == identity
                }?.isWalletAsset == true,
                "Catalog metadata replaced wallet holding for \(identity)"
            )
        }
    }
}

import SwiftUI
import UIKit

struct WalletHomeView: View {
    private static let topToolbarSymbolFont = Font.subheadline.weight(.semibold)

    let database: WalletDatabase
    let sendActivities: SendActivityStore?
    let onPendingTransaction: (WalletTransaction) -> Void
    let walletName: String
    let walletAppearanceColor: WalletAppearanceColor
    let walletAddress: String
    let permissionWalletID: String?
    let capabilities: WalletCapabilities
    let state: WalletHomeLoadState
    let presentationPreparation: WalletActionPresentationPreparation?
    let homeDisplayPreparation: WalletHomePortfolioPreparation?
    let contentRevision: UUID
    let navigationResetGeneration: UInt64
    let externalSearchPresentationRequestID: UUID?
    let onFirstRenderedFrame: @MainActor @Sendable () -> Void
    let onWalletSwitcher: () -> Void
    let onAddWallet: (HomeWalletAddAction) -> Void
    let onSettings: () -> Void
    let onOpenSettingsQuickAction: (WalletSettingsSearchRoute) -> Void
    let onOpenSettingsSearchRoute: (WalletSettingsSearchRoute) -> Void
    let onWalletSelectedFromSearch: (ManagedWallet) -> Void
    let onScan: () -> Void
    let onPasteAddress: (String) -> Void
    let onScanAsset: (WalletAsset) -> Void
    let onPasteAsset: (WalletAsset, String) -> Void
    let onSend: () -> Void
    let onSendAsset: (WalletAsset) -> Void
    let onReceive: () -> Void
    let onReceiveAsset: (WalletAsset) -> Void
    let onSeeAllAssets: () -> Void
    let onSeeAllActivity: () -> Void
    let onRetry: () -> Void
    let onRefresh: () -> Void
    let isAppSwitcherPrivacyActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.walletCurrencyContext) private var currencyContext
    @Environment(WalletSettingsStore.self) private var applicationSettings
    @State private var pendingActivity = WalletPendingActivityStore()
    @State private var isPrimaryBalanceVisible = true
    @State private var arePrimaryWalletActionsVisible = true
    @State private var isSearchPresented = false
    @State private var handledExternalSearchPresentationRequestID: UUID?
    @State private var isSearchFieldPresented = false
    @State private var searchText = ""
    @State private var universalSearchIndex: WalletUniversalSearchIndex?
    @State private var universalSearchDatabaseDependencies = WalletUniversalSearchDatabaseDependencies.empty
    @State private var universalSearchDatabaseRevision = UUID()
    @State private var isAssetsPresented = false
    @State private var managedAssets: [WalletAsset] = []
    @State private var initialAssetsNetworkID: String?
    @State private var initiallyPresentsAssetManagement = false
    @State private var managedAssetPreparation:
        WalletAssetListPreparation?
    @State private var isAllActivityPresented = false
    @State private var allActivityTransactions: [WalletTransaction] = []
    @State private var isCurrencyConverterPresented = false

    init(
        database: WalletDatabase,
        sendActivities: SendActivityStore? = nil,
        onPendingTransaction: @escaping (WalletTransaction) -> Void = { _ in },
        walletName: String = String(
            localized: "wallet.home.wallet.name.default"
        ),
        walletAppearanceColor: WalletAppearanceColor = .blue,
        walletAddress: String = "",
        permissionWalletID: String? = nil,
        capabilities: WalletCapabilities = .fullWallet,
        state: WalletHomeLoadState = .content(.sample),
        presentationPreparation: WalletActionPresentationPreparation? = nil,
        homeDisplayPreparation: WalletHomePortfolioPreparation? = nil,
        contentRevision: UUID = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        ),
        navigationResetGeneration: UInt64 = 0,
        externalSearchPresentationRequestID: UUID? = nil,
        onFirstRenderedFrame:
            @escaping @MainActor @Sendable () -> Void = {},
        onWalletSwitcher: @escaping () -> Void = {},
        onAddWallet: @escaping (HomeWalletAddAction) -> Void = { _ in },
        onSettings: @escaping () -> Void = {},
        onOpenSettingsSearchRoute:
            @escaping (WalletSettingsSearchRoute) -> Void = { _ in },
        onOpenSettingsQuickAction:
            @escaping (WalletSettingsSearchRoute) -> Void = { _ in },
        onWalletSelectedFromSearch:
            @escaping (ManagedWallet) -> Void = { _ in },
        onScan: @escaping () -> Void = {},
        onPasteAddress: @escaping (String) -> Void = { _ in },
        onScanAsset: @escaping (WalletAsset) -> Void = { _ in },
        onPasteAsset: @escaping (WalletAsset, String) -> Void = { _, _ in },
        onSend: @escaping () -> Void = {},
        onSendAsset: @escaping (WalletAsset) -> Void = { _ in },
        onReceive: @escaping () -> Void = {},
        onReceiveAsset: @escaping (WalletAsset) -> Void = { _ in },
        onSeeAllAssets: @escaping () -> Void = {},
        onSeeAllActivity: @escaping () -> Void = {},
        onRetry: @escaping () -> Void = {},
        onRefresh: @escaping () -> Void = {},
        isAppSwitcherPrivacyActive: Bool = false
    ) {
        self.database = database
        self.sendActivities = sendActivities
        self.onPendingTransaction = onPendingTransaction
        self.walletName = walletName
        self.walletAppearanceColor = walletAppearanceColor
        self.walletAddress = walletAddress
        self.permissionWalletID = permissionWalletID
        self.capabilities = capabilities
        self.state = state
        self.presentationPreparation = presentationPreparation
        self.homeDisplayPreparation = homeDisplayPreparation
        self.contentRevision = contentRevision
        self.navigationResetGeneration = navigationResetGeneration
        self.externalSearchPresentationRequestID =
            externalSearchPresentationRequestID
        self.onFirstRenderedFrame = onFirstRenderedFrame
        self.onWalletSwitcher = onWalletSwitcher
        self.onAddWallet = onAddWallet
        self.onSettings = onSettings
        self.onOpenSettingsQuickAction = onOpenSettingsQuickAction
        self.onOpenSettingsSearchRoute =
            onOpenSettingsSearchRoute
        self.onWalletSelectedFromSearch =
            onWalletSelectedFromSearch
        self.onScan = onScan
        self.onPasteAddress = onPasteAddress
        self.onScanAsset = onScanAsset
        self.onPasteAsset = onPasteAsset
        self.onSend = onSend
        self.onSendAsset = onSendAsset
        self.onReceive = onReceive
        self.onReceiveAsset = onReceiveAsset
        self.onSeeAllAssets = onSeeAllAssets
        self.onSeeAllActivity = onSeeAllActivity
        self.onRetry = onRetry
        self.onRefresh = onRefresh
        self.isAppSwitcherPrivacyActive = isAppSwitcherPrivacyActive
    }

    var body: some View {
        let pendingItems = pendingActivity.walletID == permissionWalletID
            ? pendingActivity.items(operations: sendActivities?.operations ?? [], walletAddress: walletAddress) : []
        let visibleManagedAssetIDs = managedAssets.isEmpty
            ? Set<String>()
            : WalletHomeAssetVisibility.managementVisibleAssetIDs(
                from: managedAssets,
                transactions: currentTransactions,
                walletAddress: walletAddress,
                preferencesJSON:
                    applicationSettings.assetVisibilityPreferencesJSON
            )

        return GeometryReader { geometry in
            ZStack {
                WalletTheme.groupedBackground
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

                displayedContent
                    .allowsHitTesting(!isSearchPresented)
                    .accessibilityHidden(isSearchPresented)

                if isSearchPresented {
                    searchOverlay
                        .zIndex(1)
                }

            }
            .navigationBarTitleDisplayMode(.inline)
            .background {
                WalletHomeFirstFrameObserver(
                    onFirstRenderedFrame: onFirstRenderedFrame
                )
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
            .toolbar {
                if !isSearchPresented {
                    if showsBalanceInToolbar,
                       let totalBalance =
                        state.displayedSnapshot?.totalBalance {
                        ToolbarItem(
                            id: WalletHomeWalletSwitcherToolbarID.balance,
                            placement: .topBarLeading
                        ) {
                            walletSwitcherToolbarButton(
                                maximumTitleWidth:
                                    WalletHomeTopToolbarLayout
                                    .switcherTitleMaximumWidth(
                                        containerWidth: geometry.size.width,
                                        showsPendingActivity: !pendingItems.isEmpty,
                                        showsCurrencyConverterShortcut:
                                            applicationSettings
                                            .currencyConverterHomeShortcutEnabled
                                    )
                            ) {
                                WalletHomeSwitcherBalanceTitle(
                                    totalBalance: totalBalance,
                                    currencyContext: currencyContext,
                                    isBalanceHidden: isBalanceHidden
                                )
                            }
                            .accessibilityIdentifier(WalletHomeWalletSwitcherToolbarID.balance)
                        }
                    } else {
                        ToolbarItem(
                            id: WalletHomeWalletSwitcherToolbarID.name,
                            placement: .topBarLeading
                        ) {
                            walletSwitcherToolbarButton(
                                maximumTitleWidth:
                                    WalletHomeTopToolbarLayout
                                    .switcherTitleMaximumWidth(
                                        containerWidth: geometry.size.width,
                                        showsPendingActivity: !pendingItems.isEmpty,
                                        showsCurrencyConverterShortcut:
                                            applicationSettings
                                            .currencyConverterHomeShortcutEnabled
                                    )
                            ) {
                                Text(verbatim: walletName)
                                    .font(.headline)
                                    .lineLimit(1)
                            }
                            .accessibilityIdentifier(WalletHomeWalletSwitcherToolbarID.name)
                        }
                    }

                    if !pendingItems.isEmpty || pendingActivity.isPresented || pendingActivity.selection != nil {
                        WalletToolbarSpacer(.fixed, placement: .topBarLeading)
                        ToolbarItem(id: "wallet-home-pending", placement: .topBarLeading) {
                            WalletPendingActivityToolbarButton(store: pendingActivity, items: pendingItems,
                                maximumHeight: min(480, geometry.size.height * 0.65), onOpen: openPendingActivity)
                        }
                    }

                    ToolbarItem(
                        id: "wallet-home-add-wallet",
                        placement: .topBarTrailing
                    ) {
                        WalletHomeAddWalletMenu(onAddWallet: onAddWallet)
                    }

                    if applicationSettings
                        .currencyConverterHomeShortcutEnabled {
                        WalletToolbarSpacer(.fixed, placement: .topBarTrailing)
                        ToolbarItem(
                            id: "wallet-home-currency-converter",
                            placement: .topBarTrailing
                        ) {
                            Button(action: UniHaptic.action(nil) {
                                isCurrencyConverterPresented = true
                            }) {
                                Image(systemName: "arrow.left.arrow.right")
                                    .font(Self.topToolbarSymbolFont)
                            }
                            .accessibilityLabel(
                                Text("settings.converter.title")
                            )
                            .accessibilityIdentifier(
                                "wallet-home-currency-converter"
                            )
                        }
                    }

                    if showsCompactBottomActions {
                        WalletToolbarSpacer(.fixed, placement: .topBarTrailing)

                        ToolbarItem(
                            id: "wallet-home-settings-top",
                            placement: .topBarTrailing
                        ) {
                            topSettingsControl
                        }
                    }
                }

                WalletToolbarSpacer(.flexible, placement: .bottomBar)

                ToolbarItem(
                    id: "wallet-home-settings",
                    placement: .bottomBar
                ) {
                    bottomTrailingControl
                }
            }
            .toolbar(.visible, for: .bottomBar)
            .background {
                GeometryReader { geometry in
                    WalletHomeBottomToolbarHost(
                        containerWidth: geometry.size.width,
                        showsCompactActions: showsCompactBottomActions,
                        text: $searchText,
                        isPresented: $isSearchFieldPresented,
                        requestsSearchFocus: isSearchPresented,
                        onSend: {
                            performCompactWalletAction(
                                haptic: .commit,
                                action: onSend
                            )
                        },
                        onReceive: {
                            performCompactWalletAction(
                                haptic: .selection,
                                action: onReceive
                            )
                        }
                    )
                }
            }
            .navigationDestination(isPresented: $isAssetsPresented) {
                WalletAssetsView(
                    database: database,
                    assets: managedAssets,
                    transactions: currentTransactions,
                    preparation: managedAssetPreparation,
                    contentRevision: contentRevision,
                    initialNetworkID: initialAssetsNetworkID,
                    initiallyPresentsManagement:
                        initiallyPresentsAssetManagement,
                    capabilities: capabilities,
                    isBalanceHidden: isBalanceHidden,
                    isVisible: { asset in
                        visibleManagedAssetIDs.contains(
                            AssetIdentityKey.canonical(asset.id)
                        )
                    },
                    onVisibilityChanged: setAssetVisibility,
                    onTokenAdded: addCustomToken,
                    onSendAsset: onSendAsset,
                    onReceiveAsset: onReceiveAsset,
                    onScanAsset: onScanAsset,
                    onPasteAsset: onPasteAsset
                )
            }
            .navigationDestination(isPresented: $isAllActivityPresented) {
                WalletActivityView(
                    transactions: allActivityTransactions,
                    networkValueAssets: currentAssets,
                    contentRevision: contentRevision,
                    isBalanceHidden: isBalanceHidden
                )
            }
            .sheet(isPresented: $isCurrencyConverterPresented) {
                NavigationStack {
                    Group {
                        HomeCurrencyConverterSheet(database: database)
                    }

                }
                .walletSheetPresentation(nativeGlass: false)
                .presentationDetents(
                    HomeCurrencyConverterSheetDetentPolicy.allowedDetents
                )
                .presentationDragIndicator(.visible)
            }
            .onChange(of: contentRevision) { _, _ in
                refreshPresentedCollections()
            }
            .onChange(of: navigationResetGeneration) { _, _ in
                dismissChildOwnedPresentedContent()
            }
            .task(id: permissionWalletID) {
                await pendingActivity.observe(database: database, walletID: permissionWalletID)
            }
            .onChange(of: pendingActivity.isPresented) { _, presented in
                sendActivities?.isActivityListPresented = presented
            }
            .onChange(of: isAppSwitcherPrivacyActive) { _, active in
                if active { pendingActivity.isPresented = false }
            }
            .onDisappear {
                pendingActivity.isPresented = false
                sendActivities?.isActivityListPresented = false
            }
            .task(id: externalSearchPresentationRequestID) {
                presentExternalSearchRequestIfNeeded()
            }
            .onChange(of: isSearchFieldPresented) { _, isPresented in
                synchronizeSearchOverlay(with: isPresented)
            }
            .onAppear {
                UniHaptic.prepare(.selection)
                UniHaptic.prepare(.commit)
            }
            .task(id: universalSearchObservationRequest) {
                await observeUniversalSearchDatabaseDependencies()
            }
            .task(id: universalSearchPreparationRequest) {
                guard universalSearchPreparationRequest != nil else { return }
                await prepareUniversalSearchIndex()
            }
        }
    }

    @ViewBuilder
    private var displayedContent: some View {
        stateContent
    }

    @ViewBuilder
    private var stateContent: some View {
        if let snapshot = state.displayedSnapshot {
            portfolioView(snapshot: snapshot)
        } else {
            WalletHomeFailureStateView(onRetry: onRetry)
        }
    }

    private func portfolioView(
        snapshot: WalletHomeSnapshot
    ) -> some View {
        WalletHomePortfolioView(
            database: database,
            snapshot: snapshot,
            walletAddress: walletAddress,
            capabilities: capabilities,
            permissionWalletID: permissionWalletID,
            preparation: homeDisplayPreparation
                ?? presentationPreparation?.home,
            onSend: onSend,
            onSendAsset: onSendAsset,
            onReceive: onReceive,
            onScan: onScan,
            onPasteAddress: onPasteAddress,
            onScanAsset: onScanAsset,
            onPasteAsset: onPasteAsset,
            onReceiveAsset: onReceiveAsset,
            onManageAssets: { assets in
                managedAssets = assets
                managedAssetPreparation =
                    presentationPreparation?.assetLists
                initialAssetsNetworkID = nil
                initiallyPresentsAssetManagement = false
                isAssetsPresented = true
                onSeeAllAssets()
            },
            onAssetVisibilityChanged: setAssetVisibility,
            onAssetPinChanged: setAssetPinned,
            onShowAllActivity: { transactions in
                allActivityTransactions = transactions
                isAllActivityPresented = true
                onSeeAllActivity()
            },
            onBalanceVisibilityChanged: updatePrimaryBalanceVisibility,
            onWalletActionsVisibilityChanged: { isVisible in
                guard arePrimaryWalletActionsVisible != isVisible else {
                    return
                }
                arePrimaryWalletActionsVisible = isVisible
            },
            onRefresh: onRefresh,
            isAppSwitcherPrivacyActive: isAppSwitcherPrivacyActive
        )
    }

    private func walletSwitcherToolbarButton<Title: View>(
        maximumTitleWidth: CGFloat,
        @ViewBuilder title: () -> Title
    ) -> some View {
        WalletHomeWalletSwitcherToolbarButton(
            color: walletAppearanceColor,
            maximumTitleWidth: maximumTitleWidth,
            walletName: walletName,
            accessibilityValue: walletSwitcherAccessibilityValue,
            action: onWalletSwitcher,
            title: title
        )
    }

    @MainActor
    private func updatePrimaryBalanceVisibility(_ isVisible: Bool) {
        guard isPrimaryBalanceVisible != isVisible else { return }
        withAnimation(
            reduceMotion ? nil : .smooth(duration: 0.3)
        ) {
            isPrimaryBalanceVisible = isVisible
        }
    }

    private var showsBalanceInToolbar: Bool {
        !isPrimaryBalanceVisible && state.displayedSnapshot != nil
    }

    private var showsCompactBottomActions: Bool {
        state.displayedSnapshot != nil
            && !arePrimaryWalletActionsVisible
            && !isSearchPresented
    }

    private var formattedTotalBalance: String {
        guard let totalBalance = state.displayedSnapshot?.totalBalance else {
            return walletName
        }
        return EnglishNumbers.currency(
            totalBalance,
            using: currencyContext
        )
    }

    private var walletSwitcherAccessibilityValue: String {
        guard state.displayedSnapshot != nil else { return "" }
        return isBalanceHidden
            ? WalletLocalization.string("wallet.home.balance.hidden")
            : formattedTotalBalance
    }

    @ViewBuilder
    private var bottomTrailingControl: some View {
        if showsSettingsInBottomBar {
            quickActionsMenu
        } else {
            Button(action: UniHaptic.action(nil, perform: handleBottomTrailingControl)) {
                Image(systemName: bottomTrailingSymbolName)
                    .foregroundStyle(WalletTheme.primaryLabel)
                    .contentTransition(.symbolEffect(.replace))
            }
            .animation(
                reduceMotion ? nil : .smooth(duration: 0.2),
                value: isSearchPresented
            )
            .animation(
                reduceMotion ? nil : .smooth(duration: 0.2),
                value: showsCompactBottomActions
            )
            .accessibilityLabel(
                Text(bottomTrailingAccessibilityLabelKey)
            )
        }
    }

    private var topSettingsControl: some View {
        quickActionsMenu
    }

    private var quickActionsMenu: some View {
        WalletHomeQuickActionsMenu(onSelect: handleQuickAction)
    }

    private var bottomTrailingSymbolName: String {
        if isSearchPresented {
            return "xmark"
        }
        if showsCompactBottomActions {
            return "magnifyingglass"
        }
        return "gearshape.2"
    }

    private var bottomTrailingAccessibilityLabelKey:
        LocalizedStringKey {
        if isSearchPresented {
            return "wallet.home.search.close.accessibility"
        }
        if showsCompactBottomActions {
            return "wallet.search.start.title"
        }
        return "wallet.home.action.more"
    }

    private var showsSettingsInBottomBar: Bool {
        !isSearchPresented && !showsCompactBottomActions
    }

    @MainActor
    private func performCompactWalletAction(
        haptic: UniHaptic,
        action: () -> Void
    ) {
        UniHaptic.play(haptic)
        action()
    }

    private var currentTransactions: [WalletTransaction] {
        guard case let .content(snapshot) = state else { return [] }
        return snapshot.transactions
    }

    private var currentAssets: [WalletAsset] {
        state.displayedSnapshot?.assets ?? []
    }

    private var currentDisplayAssets: [WalletAsset] {
        guard let snapshot = state.displayedSnapshot else { return [] }
        return capabilities.filteredAssets(
            WalletHomeAssetCatalog.availableAssets(from: snapshot.assets)
        )
    }

    private var currentDisplayTransactions: [WalletTransaction] {
        guard let snapshot = state.displayedSnapshot else { return [] }
        return capabilities.filteredTransactions(snapshot.transactions)
    }

    @MainActor
    private func handleBottomTrailingControl() {
        if isSearchPresented {
            UniHaptic.play(.selection)
            closeSearch()
            return
        }
        if showsCompactBottomActions {
            handleSearchButton()
            return
        }
    }

    @MainActor
    private func handleQuickAction(_ action: WalletHomeQuickAction) {
        switch action {
        case .currency:
            // Currency stays inside the quick-actions presentation.
            return
        case .security:
            UniHaptic.play(.selection)
            onOpenSettingsQuickAction(.security)
        case .backupAndKeys:
            UniHaptic.play(.selection)
            onOpenSettingsQuickAction(.backupAndKeys)
        case .settings:
            handleSettingsButton()
        }
    }

    @MainActor
    private func handleSearchButton() {
        withAnimation(
            reduceMotion ? nil : .smooth(duration: 0.24)
        ) {
            isSearchPresented = true
        }
        scheduleSelectionHaptic()
    }

    @MainActor
    private func presentExternalSearchRequestIfNeeded() {
        guard let requestID = externalSearchPresentationRequestID,
              handledExternalSearchPresentationRequestID != requestID else {
            return
        }
        handledExternalSearchPresentationRequestID = requestID
        guard !isSearchPresented else { return }
        withAnimation(
            reduceMotion ? nil : .smooth(duration: 0.24)
        ) {
            isSearchPresented = true
        }
    }

    @MainActor
    private func handleSettingsButton() {
        onSettings()
        scheduleSelectionHaptic()
    }

    @MainActor
    private func scheduleSelectionHaptic(
    ) {
        Task { @MainActor in
            await Task.yield()
            UniHaptic.play(.selection)
        }
    }

    @MainActor
    private func closeSearch() {
        isSearchFieldPresented = false
        searchText = ""
        withAnimation(
            reduceMotion ? nil : .smooth(duration: 0.24)
        ) {
            isSearchPresented = false
        }
    }

    private var isBalanceHidden: Bool {
        applicationSettings.balancePrivacyEnabled
            || isAppSwitcherPrivacyActive
    }

    private func setAssetVisibility(
        _ asset: WalletAsset,
        _ isVisible: Bool
    ) {
        guard let json = WalletHomeAssetVisibility.updatedPreferencesJSON(
            setting: isVisible,
            for: asset,
            walletAddress: walletAddress,
            preferencesJSON:
                applicationSettings.assetVisibilityPreferencesJSON
        ) else {
            return
        }
        applicationSettings.setAssetVisibilityPreferencesJSON(json)
    }

    private func setAssetPinned(
        _ asset: WalletAsset,
        _ isPinned: Bool
    ) {
        guard let json = WalletHomeAssetVisibility.updatedPreferencesJSON(
            settingPinned: isPinned,
            for: asset,
            walletAddress: walletAddress,
            preferencesJSON:
                applicationSettings.assetVisibilityPreferencesJSON
        ) else {
            return
        }
        applicationSettings.setAssetVisibilityPreferencesJSON(json)
    }

    @MainActor
    private func addCustomToken(_ asset: WalletAsset) {
        if let index = managedAssets.firstIndex(where: {
            $0.id.caseInsensitiveCompare(asset.id) == .orderedSame
        }) {
            managedAssets[index] = asset
        } else {
            managedAssets.append(asset)
        }
        setAssetVisibility(asset, true)

        onRefresh()
    }

    @MainActor
    private func refreshPresentedCollections() {
        if isAssetsPresented {
            managedAssets = currentDisplayAssets
            managedAssetPreparation =
                presentationPreparation?.assetLists
        }
        if isAllActivityPresented {
            allActivityTransactions = currentDisplayTransactions
        }
    }

    @ViewBuilder
    private var searchOverlay: some View {
        WalletHomeSearchView(
            database: database,
            query: searchText,
            index: universalSearchIndex,
            assets: searchAssets,
            transactions: searchTransactions,
            walletAddress: walletAddress,
            capabilities: capabilities,
            isBalanceHidden: isBalanceHidden,
            onSendAsset: onSendAsset,
            onReceiveAsset: onReceiveAsset,
            onScanAsset: onScanAsset,
            onPasteAsset: onPasteAsset,
            onAction: handleUniversalSearchAction,
            onWalletSelected: { wallet in
                closeSearch()
                onWalletSelectedFromSearch(wallet)
            },
            onNetworkSelected: { networkID in
                closeSearch()
                presentAssets(
                    networkID: networkID,
                    showsManagement: false
                )
            }
        )
        .onAppear {
        }
    }

    private var searchAssets: [WalletAsset] {
        guard case let .content(snapshot) = state else { return [] }
        return WalletHomeLiveAssetProjection.searchAssets(
            preparedAssets: (homeDisplayPreparation ?? presentationPreparation?.home)?.searchAssets,
            currentAssets: snapshot.assets,
            capabilities: capabilities
        )
    }

    private var searchTransactions: [WalletTransaction] {
        if let prepared = (
            homeDisplayPreparation
                ?? presentationPreparation?.home
        )?.searchTransactions {
            return prepared
        }
        guard case let .content(snapshot) = state else { return [] }
        return snapshot.transactions
    }

    private var universalSearchPreparationRequest:
        UniversalSearchPreparationRequest?
    {
        guard WalletUniversalSearchWorkPolicy.shouldBuildIndex(
            isPresented: isSearchPresented
        ) else {
            return nil
        }
        return UniversalSearchPreparationRequest(
            walletName: walletName,
            walletAddress: walletAddress,
            languageIdentifier:
                applicationSettings.languageIdentifier,
            contentRevision: contentRevision,
            databaseDependenciesRevision: universalSearchDatabaseRevision
        )
    }

    private var universalSearchObservationRequest:
        UniversalSearchObservationRequest
    {
        UniversalSearchObservationRequest(
            contentRevision: isSearchPresented ? contentRevision : nil
        )
    }

    @MainActor
    private func observeUniversalSearchDatabaseDependencies() async {
        let candidateAssetIDs = isSearchPresented
            ? searchAssets.map {
                AssetIdentityKey.canonical($0.id)
            }
            : []
        let assetIDs = WalletUniversalSearchWorkPolicy.observedAssetIDs(
            isPresented: isSearchPresented,
            candidateAssetIDs: candidateAssetIDs
        )
        do {
            for try await dependencies in
                database.universalSearchDatabaseDependencies(
                    assetIDs: assetIDs
                )
            {
                guard !Task.isCancelled else { return }
                guard universalSearchDatabaseDependencies
                    != dependencies else {
                    continue
                }
                universalSearchDatabaseDependencies = dependencies
                universalSearchDatabaseRevision = UUID()
            }
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }

    @MainActor
    private func prepareUniversalSearchIndex() async {
        guard WalletUniversalSearchWorkPolicy.shouldBuildIndex(
            isPresented: isSearchPresented
        ) else {
            return
        }
        let sourceAssets = searchAssets
        let sourceTransactions = searchTransactions
        let dependencies = universalSearchDatabaseDependencies
        guard !Task.isCancelled else { return }
        let index = await WalletUniversalSearchIndex.make(
            assets: sourceAssets,
            transactions: sourceTransactions,
            wallets: dependencies.wallets,
            unitUSDPricesByAssetID:
                dependencies.unitUSDPricesByAssetID
        )
        guard !Task.isCancelled, isSearchPresented else { return }
        universalSearchIndex = index
    }

    private func openPendingActivity(_ item: WalletPendingActivityItem) {
        switch item {
        case let .operation(operation): sendActivities?.openDetails(operation)
        case let .transaction(transaction):
            pendingActivity.review(transaction)
            onPendingTransaction(transaction)
        }
    }

    @MainActor
    private func dismissChildOwnedPresentedContent() {
        pendingActivity.isPresented = false
        pendingActivity.selection = nil
        isAssetsPresented = false
        isAllActivityPresented = false
        isCurrencyConverterPresented = false
        isSearchFieldPresented = false
        isSearchPresented = false
        searchText = ""
        managedAssets.removeAll(keepingCapacity: false)
        managedAssetPreparation = nil
        initialAssetsNetworkID = nil
        initiallyPresentsAssetManagement = false
        allActivityTransactions.removeAll(keepingCapacity: false)
    }

    @MainActor
    private func synchronizeSearchOverlay(with fieldIsPresented: Bool) {
        guard fieldIsPresented != isSearchPresented else { return }
        if fieldIsPresented {
            withAnimation(
                reduceMotion ? nil : .smooth(duration: 0.24)
            ) {
                isSearchPresented = true
            }
        } else {
            closeSearch()
        }
    }

    @MainActor
    private func handleUniversalSearchAction(
        _ action: WalletUniversalSearchAction
    ) {
        closeSearch()
        switch action {
        case .send:
            onSend()
        case .receive:
            onReceive()
        case .scan:
            onScan()
        case .allAssets:
            presentAssets(
                networkID: nil,
                showsManagement: false
            )
        case .manageAssets:
            presentAssets(
                networkID: nil,
                showsManagement: true
            )
        case .allActivity:
            allActivityTransactions = searchTransactions
            isAllActivityPresented = true
            onSeeAllActivity()
        case .walletSwitcher:
            onWalletSwitcher()
        case let .settings(route):
            onOpenSettingsSearchRoute(route)
        }
    }

    @MainActor
    private func presentAssets(
        networkID: String?,
        showsManagement: Bool
    ) {
        let preparation = presentationPreparation?.assetLists
        managedAssets = preparation?.assets ?? searchAssets
        managedAssetPreparation = preparation
        initialAssetsNetworkID = networkID
        initiallyPresentsAssetManagement = showsManagement
        isAssetsPresented = true
        onSeeAllAssets()
    }

}

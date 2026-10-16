import OathDiagnostics
import SwiftUI
import OathNativeRefresh
import OathDatabase

struct OathHomeScreen: View {
    // A legacy cold launch can render the Home layout before SQL metadata has
    // been migrated. The root keeps it noninteractive beneath the lock.
    let profile: OathWalletProfile?
    let session: OathWalletSession
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sheet: Sheet?
    @State private var showsScanner = false
    @State private var scannedRecipient: OathScannedRecipient?
    @State private var connectionEntry: OathWalletLinkInbox.Entry?
    @Environment(\.scenePhase) private var scenePhase
    @State private var assetPath: [OathAssetRoute] = []
    @State private var settingsDestination: SettingsDestination?
    @State private var scanError: OathRecoveryScanError?
    @State private var pendingScanError: OathRecoveryScanError?
    @State private var walletFlow: OathAdditionalWalletDestination?
    @State private var pendingWalletDestination: WalletSwitcherDestination?
    @State private var query = ""
    @State private var historyQuery = ""
    @State private var historyFilters = OathHistoryFilterSelection()
    private var assetFilters: PortfolioFilter {
        portfolioPresentation.filter.adjusted(for: assetFilterCurrency)
    }
    private var portfolioPresentation: OathHomePortfolioModel { session.homePortfolio }
    @State private var selectedTab: OathHomeTab = .wallet
    @State private var searchContext: OathHomeTab = .wallet
    @State private var searchPresented = false
    @State private var tokenSearch = OathTokenSearchModel()
    @State private var tokenSearchAttempt = 0
    private var balancesHidden: Bool { session.balancesHidden }
    private var currentWallet: WalletRecord? {
        session.wallets.first(where: { $0.id == profile?.id.uuidString })
    }
    private var walletColorHex: String? {
        currentWallet?.colorHex
    }
    @State private var scrollEffects = OathHomeScrollEffects()
    @State private var walletActionFailed = false

    private enum Sheet: Identifiable {
        case wallets, send, receive, address(OathWalletAddress), token(OathTokenDefinition, String), assetFilters
        var id: String {
            switch self {
            case .wallets: "wallets"
            case .send: "send"
            case .receive: "receive"
            case .assetFilters: "assetFilters"
            case .address(let address): address.id
            case .token(let token, let walletID): "token:\(walletID):\(token.id)"
            }
        }
    }

    private typealias SettingsDestination = OathWalletSettingsScreen.Destination

    private enum WalletSwitcherDestination {
        case add(OathAdditionalWalletDestination)
        case settings(SettingsDestination)
    }

    private func holdings(searching: Bool) -> [Holding] {
        let query = searching ? query.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (session.portfolio?.holdings ?? []).filter {
            query.isEmpty || ($0.name + " " + $0.symbol + " " + $0.networkID).localizedStandardContains(query)
                || ($0.networkID == "arc" && $0.reference == "native" && query.lowercased() == "0x3600000000000000000000000000000000000000")
                || ($0.reference != "native" && ($0.reference == query
                    || (OathImportChain(rawValue: $0.networkID)?.isEVM == true && $0.reference.lowercased() == query.lowercased())))
        }
    }

    private var searchBinding: Binding<String> {
        searchContext == .history ? $historyQuery : $query
    }
    private var searchPrompt: String {
        strings.text(searchContext == .history ? .searchTransactions : .searchAssets)
    }
    private var assetFilterCurrency: String { portfolioPresentation.currency }
    private var shouldPreparePortfolio: Bool {
        scenePhase == .active && session.isUnlocked && !session.changingWallet && !session.resetting
    }
    private var balanceHistoryVisible: Bool {
        shouldPreparePortfolio && !session.changingWallet && !session.resetting &&
        selectedTab == .wallet && assetPath.isEmpty && settingsDestination == nil &&
        sheet == nil && !showsScanner && walletFlow == nil && connectionEntry == nil &&
        profile?.id.uuidString == portfolioPresentation.walletID
    }

    private var canPresentWalletConnect: Bool {
        (OathWalletConnectService.shared.needsPresentation || OathWalletLinkInbox.shared.pending != nil) &&
        session.isUnlocked && scenePhase == .active && !session.changingWallet && !session.resetting &&
        !showsScanner && scannedRecipient == nil && sheet == nil && settingsDestination == nil && walletFlow == nil && connectionEntry == nil
    }
    var body: some View {
        tabs
        .tint(Color(uiColor: .label))
        .background {
            // This narrow observation boundary consumes checkpoint/timestamp
            // updates without rebuilding tabs, navigation and the scroll host.
            OathHomePortfolioUpdates(session: session, query: query, active: shouldPreparePortfolio)
        }
        .environment(\.oathScanSession, session)
        .task(id: scenePhase == .active && session.isUnlocked) {
            guard scenePhase == .active, session.isUnlocked else { return }
            OathWalletConnectService.shared.configure(session: session)
            await OathWalletConnectService.shared.retryDisconnections()
        }
        .oathScannerCover(isPresented: $showsScanner, onDismiss: {
            if scannedRecipient != nil, session.isUnlocked, !session.changingWallet, !session.resetting {
                sheet = .send
            } else { scannedRecipient = nil }
        }) {
            OathScanner(strings: strings, onPayload: { _ in showsScanner = false },
                onFailure: { _ in showsScanner = false }, onClose: { showsScanner = false },
                title: .scan, identifier: "home.scanner.camera", context: .home,
                onSelectAsset: { result in
                    guard session.isUnlocked, !session.changingWallet, !session.resetting else { showsScanner = false; return }
                    scannedRecipient = result; showsScanner = false
                }).environment(\.oathScanSession, session)
        }
        .sheet(item: $connectionEntry, onDismiss: {
            OathWalletLinkInbox.shared.didDismiss()
            OathWalletConnectService.shared.presentationDidDismiss()
        }) { entry in
            OathWalletConnectSheet(uri: entry.uri, session: session).oathLanguage(strings.language)
        }
        .onChange(of: canPresentWalletConnect, initial: true) { _, ready in
            if ready {
                // A request on an approved session has priority over a new pairing.
                if OathWalletConnectService.shared.needsPresentation {
                    if OathWalletLinkInbox.shared.pending?.route == .connections { _ = OathWalletLinkInbox.shared.take() }
                    connectionEntry = .init(route: .connections, expires: .distantFuture)
                } else { connectionEntry = OathWalletLinkInbox.shared.take() }
            }
        }
        .onChange(of: selectedTab) { _, tab in
            OathHaptics.shared.play(.selection)
            if tab != .search {
                searchPresented = false
                searchContext = tab
            }
        }
        .task(id: "\(query)|\(profile?.id.uuidString ?? "")|\(session.isUnlocked)|\(tokenSearchAttempt)|\(selectedTab)|\(searchContext)") {
            guard session.isUnlocked, selectedTab == .search, searchContext == .wallet else { tokenSearch.reset(); return }
            let available = Set((session.portfolio?.accounts ?? []).compactMap { OathImportChain(rawValue: $0.networkID) })
            let saved = Set(holdings(searching: true).map(\.networkID))
            await tokenSearch.search(query, available: available, savedNetworks: saved)
        }
        // Preserve the presenting hierarchy while the native lock covers it.
        .onChange(of: profile?.id) { _, _ in
            assetPath.removeAll()
            query = ""; historyQuery = ""; historyFilters = .init(); tokenSearch.reset()
            if sheet?.id == "assetFilters" { sheet = nil }
        }
        .sheet(item: $sheet, onDismiss: {
            scanError = pendingScanError
            pendingScanError = nil
            scannedRecipient = nil
            // Present the next native flow only after the switcher has finished
            // dismissing. Presenting a cover from inside the sheet races UIKit.
            finishWalletSwitcherDismissal()
        }) { selection in
            Group {
                switch selection {
                case .wallets:
                    OathWalletSwitcherSheet(session: session,
                        onImport: { continueFromWalletSwitcher(.add(.importPhrase)) },
                        onImportPrivateKey: { continueFromWalletSwitcher(.add(.importPrivateKey)) },
                        onCreated: { continueFromWalletSwitcher(.add(.customize($0))) },
                        onCustomize: { continueFromWalletSwitcher(.settings(.customize($0))) },
                        onWalletSettings: { continueFromWalletSwitcher(.settings(.wallet($0))) })
                case .send: OathSendFlow(session: session, scannedRecipient: scannedRecipient)
                case .receive: OathReceivePicker(addresses: profile?.addresses ?? [], session: session)
                case .assetFilters:
                    let walletID = profile?.id.uuidString ?? ""
                    OathAssetFilterSheet(holdings: session.portfolio?.holdings ?? [], currency: assetFilterCurrency,
                                         selection: assetFilters) { selection in
                        try await session.saveAssetFilters(selection, walletID: walletID)
                    }
                case .address(let address): OathReceiveSheet(address: address, session: session)
                case .token(let token, let walletID):
                    OathTokenDetailsSheet(token: token, session: session, walletID: walletID) { query = "" }
                }
            }
            .oathLanguage(strings.language)
            .environment(\.oathScanSession, session)
        }
        .fullScreenCover(item: $settingsDestination, onDismiss: resumeCustomization) { destination in
            OathWalletSettingsScreen(session: session, destination: destination)
                .oathLanguage(strings.language)
                .environment(\.oathScanSession, session)
        }
        .fullScreenCover(item: $walletFlow, onDismiss: resumeCustomization) { start in
            OathAdditionalWalletFlow(session: session, start: start)
                .oathLanguage(strings.language)
                .environment(\.oathScanSession, session)
        }
        .onChange(of: session.isUnlocked, initial: true) { _, unlocked in
            if unlocked { resumeCustomization(); OathWalletConnectService.shared.resumeRequests() }
            else {
                pendingWalletDestination = nil
                if sheet?.id == "assetFilters" { sheet = nil }
            }
        }
        .oathHapticFeedback(.error, trigger: walletActionFailed, when: walletActionFailed)
        .alert(strings.text(.walletUnavailable), isPresented: $walletActionFailed) {
            if #available(iOS 26.0, *) {
                OathButton(role: .confirm) {}
                    .accessibilityLabel(strings.text(.done))
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            } else {
                OathButton(strings.text(.done)) {}
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            }
        }
        .alert(strings.text(.scan), isPresented: Binding(
            get: { scanError != nil }, set: { if !$0 { scanError = nil } }
        ), presenting: scanError) { error in
            if error == .denied {
                OathButton(strings.text(.openSettings)) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            if #available(iOS 26.0, *) {
                OathButton(role: .confirm) {}
                    .accessibilityLabel(strings.text(.done))
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            } else {
                OathButton(strings.text(.done)) {}
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            }
        } message: { error in
            Text(strings.text(error.message))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
            Task { await OathDiagnostics.attempt("refresh_portfolio") { try await session.refresh() } }
        }
    }

    private var tabs: some View {
        nativeTabs.tint(Color(uiColor: OathTabBarStyle.selectedColor))
    }

    @ViewBuilder private var nativeTabs: some View {
        if #available(iOS 18, *) {
            TabView(selection: $selectedTab) {
                Tab(value: .wallet) { walletNavigation } label: {
                    Image(systemName: "wallet.bifold")
                }
                .accessibilityLabel(strings.text(.walletTab))
                Tab(value: .history) { historyNavigation } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityLabel(strings.text(.historyTab))
                Tab(value: .search, role: .search) { searchNavigation } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel(strings.text(.searchTitle))
            }
            .modifier(OathSearchTabActivation())
        } else {
            TabView(selection: $selectedTab) {
                walletNavigation.tabItem {
                    Image(systemName: "wallet.bifold").accessibilityLabel(strings.text(.walletTab))
                }.tag(OathHomeTab.wallet)
                historyNavigation.tabItem {
                    Image(systemName: "clock.arrow.circlepath").accessibilityLabel(strings.text(.historyTab))
                }.tag(OathHomeTab.history)
                searchNavigation.tabItem {
                    Image(systemName: "magnifyingglass").accessibilityLabel(strings.text(.searchTitle))
                }.tag(OathHomeTab.search)
            }
        }
    }

    private var walletNavigation: some View {
        NavigationStack(path: $assetPath) {
            homeContent
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .toolbar { homeToolbar }
                .oathNativeLocalization(onArtwork: !session.isLocked && !scrollEffects.usesScrolledStatusBar,
                    navigationBackground: scrollEffects.usesScrolledStatusBar ? .visible : .hidden)
                .navigationDestination(for: OathAssetRoute.self) { route in
                    OathAssetDetailScreen(route: route, session: session).oathLanguage(strings.language)
                }
        }
        .tint(Color(uiColor: .label))
        .oathHapticFeedback(.navigate, trigger: assetPath,
                            when: session.isUnlocked && !session.changingWallet)
    }

    private var historyNavigation: some View {
        NavigationStack {
            walletHistory(query: "", visible: selectedTab == .history)
        }
        .tint(Color(uiColor: .label))
    }

    private var searchNavigation: some View {
        NavigationStack {
            Group {
                if searchContext == .history {
                    walletHistory(query: historyQuery, visible: selectedTab == .search)
                } else {
                    OathEmptyStateScrollView(centersContent: portfolioPresentation.searchRows.isEmpty && tokenSearch.results.isEmpty) {
                        Text(strings.text(.assets)).oathFont(.title3, weight: .bold)
                            .accessibilityAddTraits(.isHeader)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    } content: {
                        assetList(searching: true)
                            .padding(20).frame(maxWidth: 700).frame(maxWidth: .infinity)
                    }
                    .background(Color(uiColor: OathSurfaceColors.groupedCanvas).ignoresSafeArea())
                    .navigationTitle(strings.text(.assets))
                    .navigationBarTitleDisplayMode(.inline)
                    .oathNativeLocalization()
                }
            }
        }
        .tint(Color(uiColor: .label))
        .modifier(OathHomeSearchField(query: searchBinding, isPresented: $searchPresented, prompt: searchPrompt))
    }

    @ViewBuilder private func walletHistory(query: String, visible: Bool) -> some View {
        if let walletID = profile?.id.uuidString {
            OathChainActivityScreen(walletID: walletID, session: session, query: query, isVisible: visible,
                                    filterSelection: $historyFilters)
                .id(walletID)
        }
    }

    private var homeContent: some View {
        GeometryReader { geometry in
            let visibleHoldings = portfolioPresentation.rows
            // The native bars own the safe area. The scroll viewport starts
            // below navigation, without a second inset or a toolbar spacer.
            NativeRefreshScroll(identifier: "home.scroll", tint: .white,
                                indicator: .oathLogo,
                                labels: NativeRefreshLabels(pull: strings.text(.pullToRefresh),
                                    refreshing: strings.text(.refreshing),
                                    succeeded: strings.text(.refreshSucceeded), failed: strings.text(.refreshFailed)),
                                isEnabled: session.isUnlocked && !session.changingWallet,
                                refreshIdentity: profile?.id.uuidString, action: {
                // Coalesced with foreground refresh and independent of the
                // selected currency. Failed FX updates preserve cached rates.
                async let rates = await OathDiagnostics.attempt("exchange_rates") { try await OathExchangeRateEnvironment.shared.refresh() }
                try await session.refresh()
                _ = await rates
            }, onFailure: {}, onScroll: { scrollEffects.update(origin: $0) },
                feedback: { event in
                    switch event {
                    case .started: OathHaptics.shared.play(.refresh)
                    case .succeeded: OathHaptics.shared.play(.success)
                    case .failed: OathHaptics.shared.play(.error)
                    }
                }) {
                OathHeaderScrollContent(viewportHeight: geometry.size.height, fillsViewport: visibleHoldings.isEmpty) {
                    summary
                        // Size the colored header independently of the compact
                        // canvas/Assets gap. A minimum lets larger text and stacked
                        // actions grow naturally without clipping the controls.
                        .frame(minHeight: min(360, max(280, geometry.size.height * 0.4)), alignment: .center)
                } content: {
                    OathEmptyStateLayout(centersContent: visibleHoldings.isEmpty) {
                        assetsHeader(count: visibleHoldings.count).padding(.bottom, 16)
                        if visibleHoldings.isEmpty || !portfolioPresentation.hasPrepared {
                            assetList(searching: false, values: visibleHoldings)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, visibleHoldings.isEmpty ? 20 : 0)
                    .frame(maxWidth: 700)
                    .frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: "home.scroll.content")
                // Each asset is a native reusable row. Nesting the complete
                // LazyVStack inside one List cell would eagerly build it all.
                if portfolioPresentation.hasPrepared && !visibleHoldings.isEmpty {
                    assetRows(searching: false, values: visibleHoldings)
                    Color(uiColor: OathSurfaceColors.groupedCanvas).frame(height: 20)
                }
            }
            .background {
                // A constant viewport-sized canvas keeps the status bar covered
                // and avoids resizing Metal drawables during native scrolling.
                // The scroll content above it owns the visible lower boundary.
                OathHomeHeaderSurface(effects: scrollEffects,
                    animates: session.isUnlocked && settingsDestination == nil && sheet == nil && !showsScanner
                        && connectionEntry == nil && walletFlow == nil && assetPath.isEmpty && selectedTab == .wallet,
                    colorHex: walletColorHex)
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        .background(Color(uiColor: OathSurfaceColors.groupedCanvas).ignoresSafeArea())
        // Scroll coordinates start BELOW the native bar. No floating toolbar
        // overlaps this viewport, so use zero additional occlusion.
        .onAppear { scrollEffects.update(toolbarHeight: 0) }
        .tint(Color(uiColor: .label))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wallet.home")
    }

    private func resumeCustomization() {
        guard session.isUnlocked, settingsDestination == nil, walletFlow == nil,
              let id = session.pendingCustomizationID else { return }
        if sheet == nil {
            walletFlow = .customize(id)
        }
    }

    private func continueFromWalletSwitcher(_ destination: WalletSwitcherDestination) {
        guard session.isUnlocked, case .wallets = sheet,
              pendingWalletDestination == nil else { return }
        pendingWalletDestination = destination
        sheet = nil
    }

    private func finishWalletSwitcherDismissal() {
        let next = pendingWalletDestination
        pendingWalletDestination = nil
        guard session.isUnlocked, settingsDestination == nil, walletFlow == nil else { return }
        switch next {
        case .add(let destination):
            walletFlow = destination
        case .settings(let destination):
            // Recheck after dismissal: locking or removing a wallet can invalidate
            // a menu selection while the native sheet is animating out.
            guard let id = destination.walletID,
                  session.wallets.contains(where: { $0.id == id }) else { return }
            settingsDestination = destination
        case nil:
            resumeCustomization()
        }
    }

    private var homeToolbar: some ToolbarContent {
        OathHomeToolbar(effects: scrollEffects,
            walletName: currentWallet == nil ? strings.text(.wallets) : session.walletName(currentWallet, strings: strings),
            walletColorHex: walletColorHex,
            canSwitchWallet: session.isUnlocked && !session.changingWallet,
            onSwitchWallet: {
                guard session.isUnlocked, !session.changingWallet else { return }
                sheet = .wallets
            },
            onScan: {
                guard session.isUnlocked, !session.changingWallet else { return }
                scannedRecipient = nil; showsScanner = true
            }, onSettings: {
                guard session.isUnlocked, !session.changingWallet else { return }
                settingsDestination = .app
            }, onWalletSettings: {
                guard session.isUnlocked, !session.changingWallet, let id = profile?.id.uuidString else { return }
                settingsDestination = .wallet(id)
            })
    }

    private var totalBalance: String {
        if !portfolioPresentation.total.isEmpty { return portfolioPresentation.total }
        let currency = portfolioPresentation.currency
        let amount = OathAssetAmounts(native: nil, fiat: nil, currencyCode: currency)
        return String(OathAssetAmountFormat(locale: .autoupdatingCurrent, selectedCurrencyCode: currency).fiat(amount).characters)
    }

    private var summary: some View {
        VStack(spacing: 26) {
            VStack(spacing: 12) {
                OathButton(action: toggleBalancesHidden) {
                    VStack(spacing: 8) {
                        Text(strings.text(.totalBalance))
                            .oathFont(.subheadline, weight: .medium)
                            .foregroundStyle(.white.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("home.balanceTitle")
                        Text(balancesHidden ? "••••" : totalBalance)
                            .font(.system(size: 58, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .monospacedDigit()
                            .contentTransition(.opacity)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(strings.text(.totalBalance))
                .accessibilityValue(balancesHidden ? strings.text(.balanceHidden) : totalBalance)
                .accessibilityHint(strings.text(.hideBalance))
                .accessibilityIdentifier("home.balance")
                .onGeometryChange(for: CGFloat.self) {
                    $0.frame(in: .named("home.scroll.content")).maxY
                } action: { scrollEffects.update(balanceBottom: $0) }
                OathBalanceChangePill(session: session, visible: balanceHistoryVisible)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: OathActionMetrics.spacing) { sendAction; receiveAction }
                VStack(spacing: OathActionMetrics.spacing) { sendAction; receiveAction }
            }
            .oathActionArea(existingInset: 24)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        // Equal insets keep the title, balance and actions centered as one
        // group, including when localized actions need to stack vertically.
        .padding(.vertical, 24)
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity)
    }

    private func toggleBalancesHidden() {
        Task {
            do { try await session.toggleBalancesHidden() }
            catch { OathDiagnostics.record(error); walletActionFailed = true }
        }
    }

    private var receiveAction: some View {
        OathActionButton(title: strings.text(.receive), icon: "arrow.down.left", accent: .white, foreground: .black) {
            sheet = .receive
        }
        .disabled(profile == nil)
        .accessibilityIdentifier("home.receive")
    }

    private var sendAction: some View {
        OathActionButton(title: strings.text(.send), icon: "arrow.up.right", appearance: .secondary, foreground: .white) {
            sheet = .send
        }
        .disabled(profile == nil)
        .accessibilityIdentifier("home.send")
    }

    private func assetsHeader(count: Int) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(strings.text(.assets)).oathFont(.title3, weight: .bold)
                    .accessibilityAddTraits(.isHeader)
                if assetFilters.activeCount > 0 {
                    Text(strings.format(.assetFilterShowing, strings.number(count),
                        strings.number(portfolioPresentation.holdingCount)))
                        .oathFont(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            OathAssetFilterButton(activeCount: assetFilters.activeCount) { sheet = .assetFilters }
                .disabled(!session.isUnlocked || session.changingWallet || profile == nil)
        }
    }

    private func assetList(searching: Bool, values: [OathHomeAssetPresentation]? = nil) -> some View {
        // Sort/filter once per content change, not once again for every divider.
        let visibleHoldings = values ?? (searching ? portfolioPresentation.searchRows : portfolioPresentation.rows)
        return VStack(alignment: .leading, spacing: 16) {
            if !portfolioPresentation.hasPrepared {
                ProgressView().tint(.secondary).frame(maxWidth: .infinity)
            } else if !searching && visibleHoldings.isEmpty {
                OathEmptyState(title: strings.text(assetFilters.activeCount > 0 ? .assetFilterNoResults : .assetFilterNoAssets),
                    systemImage: assetFilters.activeCount > 0 ? "line.3.horizontal.decrease" : "square.stack.3d.up",
                    description: strings.text(assetFilters.activeCount > 0 ? .assetFilterNoResultsDetail : .assetFilterNoAssetsDetail)) {
                    if assetFilters.activeCount > 0 {
                        OathButton(strings.text(.historyResetFilters), feedback: .selection) {
                            guard let walletID = profile?.id.uuidString else { return }
                            Task {
                                do { try await session.saveAssetFilters(.init(), walletID: walletID) }
                                catch is CancellationError { }
                                catch {
                                    OathDiagnostics.record(error, component: "asset_filters", operation: "reset")
                                    walletActionFailed = true
                                }
                            }
                        }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("home.assetFilters.reset")
                    }
                }
            } else if searching && visibleHoldings.isEmpty && !tokenSearch.isAddress && !tokenSearch.invalidAddress {
                OathEmptyState(strings.text(.noSearchResults), systemImage: "magnifyingglass",
                               description: strings.format(.noSearchResultsDetail, query))
            } else {
                LazyVStack(spacing: 0) {
                    assetRows(searching: searching, values: visibleHoldings)
                }
                .padding(.horizontal, -20)
            }
            if searching && (tokenSearch.isAddress || tokenSearch.invalidAddress) {
                OathTokenSearchResults(model: tokenSearch, hasSavedMatches: !visibleHoldings.isEmpty, onSelect: { token in
                    guard let walletID = session.displayedProfile?.id.uuidString else { return }
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    sheet = .token(token, walletID)
                }, retry: { tokenSearchAttempt += 1 })
            }
        }
    }

    private func assetRows(searching: Bool, values: [OathHomeAssetPresentation]) -> some View {
        ForEach(values) { presentation in
            let item = presentation.holding
            if let chain = OathImportChain(rawValue: item.networkID) {
                OathButton {
                    guard let walletID = session.portfolio?.wallet.id else { return }
                    let current = session.portfolio?.holdings.first { $0.id == item.id } ?? item
                    let route = OathAssetRoute(walletID: walletID, holding: current)
                    if searching {
                        // End the native search session, not just keyboard focus.
                        // Home owns the detail so both Back and interactive pop
                        // return to normal browsing, never the search controller.
                        searchPresented = false
                        query = ""
                        assetPath = [route]
                        selectedTab = .wallet
                    } else {
                        assetPath.append(route)
                    }
                } label: {
                    OathHomeAssetRow(chain: chain, presentation: presentation,
                        balancesHidden: balancesHidden, showsSeparator: item.id != values.first?.id)
                        .equatable()
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier(item.reference == "native" ? "home.network.\(item.networkID)" : "home.token.\(item.assetID)")
                .frame(maxWidth: searching ? .infinity : 700)
                .frame(maxWidth: .infinity)
                .background(searching ? Color.clear : Color(uiColor: OathSurfaceColors.groupedCanvas))
            }
        }
    }
}

/// Observe raw database snapshots here, outside the expensive Home hierarchy.
/// The presentation model publishes only changed display values, immediately
/// after its background builder finishes (no timer or UI refresh throttling).
private struct OathHomePortfolioUpdates: View {
    let session: OathWalletSession
    let query: String
    let active: Bool
    @Environment(\.oathLocalizer) private var strings

    private var input: OathHomePortfolioInput {
        let snapshot = session.portfolio
        let currency = snapshot?.currency ?? "USD"
        return .init(walletID: snapshot?.wallet.id, holdings: snapshot?.holdings ?? [],
            currency: currency, total: snapshot?.totalFiat ?? .zero,
            filter: (snapshot?.assetFilter ?? .init()).adjusted(for: currency), query: query,
            formattingLocale: Locale.autoupdatingCurrent.identifier,
            sortingLocale: strings.language.locale.identifier)
    }

    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .onChange(of: input) { _, value in
                if active { session.homePortfolio.update(value) }
            }
            .onChange(of: active, initial: true) { _, active in
                if active { session.homePortfolio.update(input) }
            }
    }
}

struct OathHomeNetworkRow: View {
    let address: OathWalletAddress
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        OathSettingsRow(title: strings.invariant(address.networkName), icon: "network",
            value: strings.invariant(address.ticker),
            subtitle: strings.invariant(String(address.address.prefix(8)) + "…" + String(address.address.suffix(6))),
            networkLogo: address.logo)

    }
}

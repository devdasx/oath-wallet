import OathDiagnostics
import SwiftUI
import OathNativeRefresh
import OathDatabase
import OathAnkr

struct OathHomeScreen: View {
    private static let multisigCheck = OathTokenRPCConfiguration.bundled().makePublicMultisigCheck()
    // A legacy cold launch can render the Home layout before SQL metadata has
    // been migrated. The root keeps it noninteractive beneath the lock.
    let profile: OathWalletProfile?
    let session: OathWalletSession
    let settings: OathAppSettings
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.colorScheme) private var colorScheme
    @State private var sheet: Sheet?
    @State private var multisigFindings: [PublicMultisigEvidence] = []
    @State private var multisigFindingsWalletID: UUID?
    @State private var securityNotices = WalletSecurityNoticeQueue()
    @State private var showsScanner = false
    @State private var scannedRecipient: OathScannedRecipient?
    @State private var paymentLinkActive = false
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
    @State private var silentAssetTabSelection = false
    @State private var searchContext: OathHomeTab = .wallet
    @State private var searchPresented = false
    @State private var tokenSearch = OathTokenSearchModel()
    @State private var tokenSearchAttempt = 0
    private var tokenSearchRequest: OathTokenSearchRequest {
        var request = OathTokenSearchRequest(query: query, walletID: profile?.id.uuidString,
            active: session.isUnlocked && !session.changingWallet && !session.resetting
                && selectedTab == .search && searchContext == .wallet,
            snapshot: session.portfolio)
        request.attempt = tokenSearchAttempt
        return request
    }
    private var balancesHidden: Bool { session.balancesHidden }
    private var currentWallet: WalletRecord? {
        session.wallets.first(where: { $0.id == profile?.id.uuidString })
    }
    private var walletColorHex: String? {
        currentWallet?.colorHex
    }
    @State private var walletActionFailed = false

    private enum Sheet: Identifiable {
        case wallets, send, receive, address(OathWalletAddress), assetFilters, tronMultisigSetup(String), evmMultisigSetup(String), solanaMultisigSetup(String), xrplMultisigSetup(String), stellarMultisigSetup(String)
        case multisig(UUID, [PublicMultisigEvidence])
        case stablecoin(UUID, [StablecoinRestrictionToken])
        var id: String {
            switch self {
            case .wallets: "wallets"
            case .send: "send"
            case .receive: "receive"
            case .assetFilters: "assetFilters"
            case .xrplMultisigSetup: "xrplMultisigSetup"
            case .stellarMultisigSetup: "stellarMultisigSetup"
            case .evmMultisigSetup: "evmMultisigSetup"
            case .solanaMultisigSetup: "solanaMultisigSetup"
            case .tronMultisigSetup: "tronMultisigSetup"
            case .multisig: "multisig"
            case .stablecoin: "stablecoin"
            case .address(let address): address.id
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
        sheet == nil && !showsScanner && walletFlow == nil && !OathWalletConnectService.shared.presentationOpen &&
        profile?.id.uuidString == portfolioPresentation.walletID
    }

    private var canPresentVaultImport: Bool {
        session.isUnlocked && !session.changingWallet && !session.resetting &&
        !showsScanner && scannedRecipient == nil && sheet == nil && settingsDestination == nil && walletFlow == nil && !OathWalletConnectService.shared.presentationOpen
    }

    private var canPresentWalletLink: Bool {
        OathVaultImportInbox.shared.pending == nil && OathVaultImportInbox.shared.active == nil &&
        (OathWalletLinkInbox.shared.pending != nil && !OathWalletLinkInbox.shared.hasWalletConnectRequest) &&
        session.isUnlocked && scenePhase == .active && !session.changingWallet && !session.resetting &&
        !showsScanner && scannedRecipient == nil && sheet == nil && settingsDestination == nil && walletFlow == nil && !OathWalletConnectService.shared.presentationOpen
    }
    private var multisigAccounts: [PublicMultisigAccount] {
        Array(Set((profile?.addresses ?? []).compactMap { item in
            PublicMultisigChain(rawValue: item.chain.id).map { PublicMultisigAccount(chain: $0, address: item.address) }
        })).sorted { ($0.chain.rawValue, $0.address) < ($1.chain.rawValue, $1.address) }
    }
    private var multisigScope: String {
        guard shouldPreparePortfolio, let profile else { return "" }
        return profile.id.uuidString + multisigAccounts.map { "|\($0.chain.rawValue):\($0.address)" }.joined()
    }
    private var hasPendingMultisigNotice: Bool {
        profile.map { $0.id == multisigFindingsWalletID && session.multisigNoticeStates[$0.id]?.acknowledged == false } == true &&
        !multisigFindings.isEmpty
    }
    private var stablecoinAccounts: [StablecoinRestrictionAccount] {
        Array(Set((profile?.addresses ?? []).compactMap { item in
            StablecoinRestrictionRegistry.tokens(network: item.chain.id).isEmpty ? nil :
                StablecoinRestrictionAccount(network: item.chain.id, address: item.address)
        })).sorted { ($0.network, $0.address) < ($1.network, $1.address) }
    }
    private var stablecoinScope: String {
        guard shouldPreparePortfolio, let profile else { return "" }
        return profile.id.uuidString + stablecoinAccounts.map { "|\($0.network):\($0.address)" }.joined()
    }
    private var nextSecurityNotice: WalletSecurityNoticeQueue.Notice? {
        let state = profile.flatMap { session.stablecoinSecurityStates[$0.id] }
        let available = balanceHistoryVisible && !searchPresented && scannedRecipient == nil && pendingWalletDestination == nil &&
            session.pendingCustomizationID == nil && !OathWalletConnectService.shared.needsPresentation &&
            OathWalletLinkInbox.shared.pending == nil
        return securityNotices.next(walletID: profile?.id, homeAvailable: available,
            multisigPending: hasPendingMultisigNotice,
            stablecoinPending: state.map { !$0.acknowledged && !$0.restricted.isEmpty } == true)
    }
    private func presentNextSecurityNotice() {
        // Re-evaluate current wallet/navigation state instead of presenting a
        // candidate captured before a wallet switch or another modal opened.
        guard let next = nextSecurityNotice else { return }
        switch next.kind {
        case .multisig:
            guard securityNotices.begin(next) else { return }
            sheet = .multisig(next.walletID, multisigFindings)
        case .stablecoin:
            guard let state = session.stablecoinSecurityStates[next.walletID],
                  securityNotices.begin(next) else { return }
            sheet = .stablecoin(next.walletID, state.restricted)
        }
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
        .task(id: stablecoinScope) {
            guard !stablecoinScope.isEmpty, let walletID = profile?.id else { return }
            await session.checkStablecoinRestrictions(walletID: walletID, accounts: stablecoinAccounts)
        }
        .onChange(of: nextSecurityNotice, initial: true) { _, _ in
            presentNextSecurityNotice()
        }
        // A separate asynchronous read of public metadata. Neither initial
        // rendering, wallet import, unlock nor navigation awaits this task.
        .task(id: multisigScope) {
            let scope = multisigScope
            guard !scope.isEmpty, let walletID = profile?.id else { return }
            let noticeState = await OathDiagnostics.$operationID.withValue(UUID()) {
                await OathDiagnostics.attempt("load_multisig_notice_acknowledgement") {
                    try await session.loadMultisigNoticeState(walletID: walletID)
                }
            }
            guard let noticeState, !Task.isCancelled, scope == multisigScope else { return }
            guard !noticeState.acknowledged else { return }
            let accounts = multisigAccounts
            var findings: [PublicMultisigEvidence] = []
            // At most four concurrent checks, including restored wallets with
            // many public accounts. No request on every balance refresh/frame.
            for start in stride(from: 0, to: accounts.count, by: 4) {
                guard !Task.isCancelled else { return }
                let batch = Array(accounts[start..<min(start + 4, accounts.count)])
                findings += await withTaskGroup(of: PublicMultisigEvidence?.self) { group in
                    for account in batch {
                        group.addTask {
                            if case .confirmed(let evidence) = await Self.multisigCheck.check(account) { return evidence }
                            return nil
                        }
                    }
                    var result: [PublicMultisigEvidence] = []
                    for await item in group { if let item { result.append(item) } }
                    return result
                }
            }
            guard !Task.isCancelled, scope == multisigScope else { return }
            multisigFindingsWalletID = walletID
            multisigFindings = findings
                .sorted { ($0.account.chain.rawValue, $0.account.address) < ($1.account.chain.rawValue, $1.account.address) }
        }
        .task(id: scenePhase == .active && session.isUnlocked) {
            guard scenePhase == .active, session.isUnlocked else { return }
            OathWalletConnectService.shared.configure(session: session)
            await OathWalletConnectService.shared.retryDisconnections()
            OathWalletConnectService.shared.resumeRequests()
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
        .oathWalletConnectPresentation(session: session)
        .oathVaultImport(session: session, canPresent: canPresentVaultImport)
        .onChange(of: canPresentWalletLink, initial: true) { _, ready in
            if ready, let entry = OathWalletLinkInbox.shared.take(), case .payment(let recipient) = entry.route {
                paymentLinkActive = true
                scannedRecipient = recipient
                sheet = .send
            }
        }
        .onChange(of: selectedTab) { _, tab in
            if !silentAssetTabSelection || tab != .wallet { OathHaptics.shared.play(.selection) }
            silentAssetTabSelection = false
            if tab != .search {
                searchPresented = false
                searchContext = tab
            }
        }
        .task(id: tokenSearchRequest) {
            let request = tokenSearchRequest
            await tokenSearch.search(request)
        }
        .task(id: session.isUnlocked) {
            guard session.isUnlocked else { return }
            // Let the first Home frame and wallet navigation settle. Catalog
            // download/indexing live on their own actor and never gate Home.
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            _ = await TokenDiscoveryCatalog.shared.refreshIfNeeded()
        }
        // Preserve the presenting hierarchy while the native lock covers it.
        .onChange(of: profile?.id) { _, _ in
            multisigFindings = []
            if sheet?.id == "multisig" { sheet = nil }
            if sheet?.id == "stablecoin" { sheet = nil }
            assetPath.removeAll()
            query = ""; historyQuery = ""; historyFilters = .init(); tokenSearch.reset()
            if sheet?.id == "assetFilters" { sheet = nil }
        }
        .sheet(item: $sheet, onDismiss: {
            // One slot for both warnings. Acknowledging either must not allow
            // the other to race the outgoing sheet's native animation.
            securityNotices.didDismiss()
            scanError = pendingScanError
            pendingScanError = nil
            scannedRecipient = nil
            if paymentLinkActive {
                paymentLinkActive = false
                OathWalletLinkInbox.shared.didDismiss()
            }
            // Present the next native flow only after the switcher has finished
            // dismissing. Presenting a cover from inside the sheet races UIKit.
            finishWalletSwitcherDismissal()
        }) { selection in
            Group {
                switch selection {
                case .stellarMultisigSetup(let walletID):
                    NavigationStack { OathStellarMultisigSetupScreen(session: session, walletID: walletID) }
                case .xrplMultisigSetup(let walletID):
                    NavigationStack { OathXrplMultisigSetupScreen(session: session, walletID: walletID) }
                case .evmMultisigSetup(let walletID):
                    NavigationStack { OathEVMMultisigSetupScreen(session: session, walletID: walletID) }
                case .solanaMultisigSetup(let walletID):
                    NavigationStack { OathSolanaMultisigSetupScreen(session: session, walletID: walletID) }
                case .tronMultisigSetup(let walletID):
                    NavigationStack { OathTronMultisigSetupScreen(session: session, walletID: walletID) }
                case .stablecoin(let walletID, let tokens):
                    OathStablecoinRestrictionNotice(tokens: tokens) {
                        try await session.acknowledgeStablecoinSecurity(walletID: walletID)
                        if session.isUnlocked, !session.changingWallet, session.displayedProfile?.id == walletID {
                            sheet = nil
                        }
                    }
                case .multisig(let walletID, let evidence):
                    OathMultisigNotice(evidence: evidence) {
                        try await session.acknowledgeMultisigNotice(walletID: walletID)
                        if session.isUnlocked, !session.changingWallet,
                           session.displayedProfile?.id == walletID, multisigFindingsWalletID == walletID {
                            multisigFindings = []
                            sheet = nil
                        }
                    }
                case .wallets:
                    OathWalletSwitcherSheet(session: session,
                        onCreated: { continueFromWalletSwitcher(.add(.customize($0))) },
                        onCustomize: { continueFromWalletSwitcher(.settings(.customize($0))) })
                        .environment(settings)
                case .send: OathSendFlow(session: session, scannedRecipient: scannedRecipient)
                case .receive: OathReceivePicker(addresses: profile?.addresses ?? [], session: session)
                case .assetFilters:
                    let walletID = profile?.id.uuidString ?? ""
                    OathAssetFilterSheet(holdings: session.portfolio?.holdings ?? [], currency: assetFilterCurrency,
                                         selection: assetFilters) { selection in
                        try await session.saveAssetFilters(selection, walletID: walletID)
                    }
                case .address(let address): OathReceiveSheet(address: address, session: session)
                }
            }
            .oathLanguage(strings.language)
            .environment(\.oathScanSession, session)
        }
        .fullScreenCover(item: $settingsDestination, onDismiss: resumeCustomization) { destination in
            OathWalletSettingsScreen(session: session, destination: destination)
                // iOS-on-Mac can create a separate presentation environment.
                // Settings and its alert/navigation children require the SAME
                // scene-owned preferences, not a newly created fallback model.
                .environment(settings)
                .oathLanguage(strings.language)
                .environment(\.oathScanSession, session)
        }
        .fullScreenCover(item: $walletFlow, onDismiss: resumeCustomization) { start in
            OathAdditionalWalletFlow(session: session, start: start)
                .environment(settings)
                .oathLanguage(strings.language)
                .environment(\.oathScanSession, session)
        }
        .onChange(of: session.isUnlocked, initial: true) { _, unlocked in
            if unlocked { resumeCustomization(); OathWalletConnectService.shared.resumeRequests() }
            else {
                pendingWalletDestination = nil
                multisigFindings = []
                if sheet?.id == "multisig" { sheet = nil }
                if sheet?.id == "stablecoin" { sheet = nil }
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
                // Asset details hide the tab bar. Restore it as part of the
                // pop transition, before Home's viewport sizes its header.
                .toolbar(.visible, for: .tabBar)
                .toolbar { homeToolbar }
                // Native bars own both contrast and scroll-edge transitions.
                // Artwork white must not follow the bar over the Assets canvas.
                .oathArtworkAppBar()
                .navigationDestination(for: OathAssetRoute.self) { route in
                    OathAssetDetailScreen(route: route, session: session).oathLanguage(strings.language)
                }
        }
        .tint(Color(uiColor: .label))
    }

    private var historyNavigation: some View {
        NavigationStack {
            walletHistory(query: "", visible: selectedTab == .history)
        }
        // The stack owns pushed receipts even when this tab is inactive.
        // Replacing only its root list leaves the previous wallet's receipt open.
        .id(profile?.id)
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
        // History search can also retain a pushed transaction across tab changes.
        .id(profile?.id)
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
                                indicator: .progressRing, timing: .brief,
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
            }, onFailure: {}, onScroll: { _ in },
                feedback: { event in
                    switch event {
                    case .pullStep: OathHaptics.shared.play(.selection)
                    case .started: OathHaptics.shared.play(.refresh)
                    case .succeeded: OathHaptics.shared.play(.success)
                    case .finished: OathHaptics.shared.play(.success)
                    case .failed: OathHaptics.shared.play(.error)
                    }
                }) {
                OathHeaderScrollContent(viewportHeight: geometry.size.height, fillsViewport: visibleHoldings.isEmpty) {
                    summary(viewportHeight: geometry.size.height, bottomSafeAreaInset: geometry.safeAreaInsets.bottom)
                } content: {
                    OathEmptyStateLayout(centersContent: visibleHoldings.isEmpty) {
                        if currentWallet?.kind == "tronMultisig", let walletID = currentWallet?.id {
                            OathButton { sheet = .tronMultisigSetup(walletID) } label: {
                                OathSettingsRow(title: strings.text(.multisigTronSetup), icon: "signature",
                                    subtitle: strings.text(.multisigTronHomeDetail))
                            }.buttonStyle(OathSettingsRowButtonStyle())
                        }
                        if currentWallet?.kind == "stellarMultisig", let walletID = currentWallet?.id {
                            OathButton { sheet = .stellarMultisigSetup(walletID) } label: {
                                OathSettingsRow(title: strings.text(.multisigStellarSetup), icon: "signature",
                                    subtitle: strings.text(.multisigStellarHomeDetail))
                            }.buttonStyle(OathSettingsRowButtonStyle())
                        }
                        if currentWallet?.kind == "xrplMultisig", let walletID = currentWallet?.id {
                            OathButton { sheet = .xrplMultisigSetup(walletID) } label: {
                                OathSettingsRow(title: strings.text(.multisigXrplSetup), icon: "signature",
                                    subtitle: strings.text(.multisigXrplHomeDetail))
                            }.buttonStyle(OathSettingsRowButtonStyle())
                        }
                        if currentWallet?.kind == "evmMultisig", let walletID = currentWallet?.id {
                            OathButton { sheet = .evmMultisigSetup(walletID) } label: {
                                OathSettingsRow(title: strings.text(.multisigEVMSetup), icon: "signature",
                                    subtitle: strings.text(.multisigEVMHomeDetail))
                            }.buttonStyle(OathSettingsRowButtonStyle())
                        }
                        if currentWallet?.kind == "solanaMultisig", let walletID = currentWallet?.id {
                            OathButton { sheet = .solanaMultisigSetup(walletID) } label: {
                                OathSettingsRow(title: strings.text(.multisigSolanaSetup), icon: "signature",
                                    subtitle: strings.text(.multisigSolanaHomeDetail))
                            }.buttonStyle(OathSettingsRowButtonStyle())
                        }
                        assetsHeader.padding(.bottom, 16)
                        if visibleHoldings.isEmpty || !portfolioPresentation.hasPrepared {
                            assetList(searching: false, values: visibleHoldings)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, visibleHoldings.isEmpty ? 20 : 0)
                    .frame(maxWidth: 700)
                    .frame(maxWidth: .infinity)
                }
                // Each asset is a native reusable row. Nesting the complete
                // LazyVStack inside one List cell would eagerly build it all.
                if portfolioPresentation.hasPrepared && !visibleHoldings.isEmpty {
                    assetRows(searching: false, values: visibleHoldings)
                    Color.clear.frame(height: 20)
                }
            }
            // Renew native cells and refresh together; preserve the screen's
            // wallet, navigation, search and filter state above this boundary.
            .id(strings.language.isRightToLeft)
            .modifier(OathHomeScrollEdgeAppearance())
            .modifier(OathHeaderScrollBackground {
                // The shared surface supplies dark-mode frost and a light-mode canvas.
                OathHomeHeaderSurface(animates: session.isUnlocked && settingsDestination == nil && sheet == nil && !showsScanner
                        && !OathWalletConnectService.shared.presentationOpen && walletFlow == nil && assetPath.isEmpty && selectedTab == .wallet,
                    colorHex: walletColorHex)
            })
        }
        .background(Color(uiColor: OathSurfaceColors.groupedCanvas).ignoresSafeArea())
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
        OathHomeToolbar(
            walletName: currentWallet == nil ? strings.text(.wallets) : session.walletName(currentWallet, strings: strings),
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
            })
    }

    private var totalBalance: String {
        if !portfolioPresentation.total.isEmpty { return portfolioPresentation.total }
        let currency = portfolioPresentation.currency
        let amount = OathAssetAmounts(native: nil, fiat: nil, currencyCode: currency)
        return String(OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: currency).fiat(amount).characters)
    }

    private func summary(viewportHeight: CGFloat, bottomSafeAreaInset: CGFloat) -> some View {
        OathWalletSummaryLayout(viewportHeight: viewportHeight, bottomSafeAreaInset: bottomSafeAreaInset) {
            VStack(spacing: 12) {
                OathButton(action: toggleBalancesHidden) {
                    VStack(spacing: 8) {
                        Text(strings.text(.totalBalance))
                            .oathFont(.subheadline, weight: .medium)
                            .foregroundStyle(.white.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("home.balanceTitle")
                        Text(totalBalance)
                            .font(.system(size: 58, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .monospacedDigit()
                            .contentTransition(.opacity)
                            .oathBalanceConcealed(balancesHidden, radius: 22)
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
        OathActionButton(title: strings.text(.receive), icon: "qrcode", appearance: .secondary, foreground: .white) {
            sheet = .receive
        }
        .disabled(profile == nil)
        .accessibilityIdentifier("home.receive")
    }

    private var sendAction: some View {
        OathActionButton(title: strings.text(.send), icon: "paperplane", appearance: .secondary, foreground: .white) {
            sheet = .send
        }
        .disabled(profile == nil)
        .accessibilityIdentifier("home.send")
    }

    private var assetsHeader: some View {
        OathAssetsToolbar(activeCount: assetFilters.activeCount,
            isEnabled: session.isUnlocked && !session.changingWallet && profile != nil) {
                sheet = .assetFilters
            }
            // UIKit retains 16-point content insets independently of
            // layoutMargins. Cancel those; the panel supplies 20 points.
            .padding(.horizontal, -16)
    }

    private func assetList(searching: Bool, values: [OathHomeAssetPresentation]? = nil) -> some View {
        // Sort/filter once per content change, not once again for every divider.
        let visibleHoldings = values ?? (searching ? portfolioPresentation.searchRows : portfolioPresentation.rows)
        return VStack(alignment: .leading, spacing: 0) {
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
            } else if searching && visibleHoldings.isEmpty && !tokenSearchRequest.hasQuery {
                OathEmptyState(strings.text(.noSearchResults), systemImage: "magnifyingglass",
                               description: strings.format(.noSearchResultsDetail, query))
            } else {
                LazyVStack(spacing: 0) {
                    assetRows(searching: searching, values: visibleHoldings)
                }
                .padding(.horizontal, -20)
            }
            if searching && tokenSearchRequest.hasQuery {
                OathTokenSearchResults(model: tokenSearch, session: session, walletID: tokenSearchRequest.walletID,
                    active: tokenSearchRequest.active, hasSavedMatches: !visibleHoldings.isEmpty,
                    balancesHidden: balancesHidden, onSelected: { holding, snapshot in
                        searchPresented = false
                        query = ""
                        assetPath = [OathAssetRoute(walletID: snapshot.wallet.id, holding: holding)]
                        silentAssetTabSelection = selectedTab != .wallet
                        selectedTab = .wallet
                    }, retry: { tokenSearchAttempt += 1 })
                    .padding(.horizontal, -20)
            }
        }
    }

    @ViewBuilder private func assetRows(searching: Bool, values: [OathHomeAssetPresentation]) -> some View {
        if !searching && !portfolioPresentation.treeRows.isEmpty {
            ForEach(portfolioPresentation.treeRows) { entry in
                if let presentation = entry.presentation {
                    assetRow(searching: false, presentation: presentation,
                             showsSeparator: !entry.isChild && entry.id != portfolioPresentation.treeRows.first?.id,
                             tree: entry)
                } else if let chain = OathImportChain(rawValue: entry.networkID) {
                    OathAssetTreeRow(entry: entry) {
                        OathAssetTreeHeading(chain: chain)
                    }
                    .frame(maxWidth: 700).frame(maxWidth: .infinity)
                }
            }
        } else {
            ForEach(values) { presentation in
                assetRow(searching: searching, presentation: presentation,
                         showsSeparator: presentation.id != values.first?.id)
            }
        }
    }

    @ViewBuilder private func assetRow(searching: Bool, presentation: OathHomeAssetPresentation,
                                      showsSeparator: Bool, tree: OathHomeAssetTreeEntry? = nil) -> some View {
            let item = presentation.holding
            if let chain = OathImportChain(rawValue: item.networkID) {
                OathButton(feedback: nil) {
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
                        silentAssetTabSelection = selectedTab != .wallet
                        selectedTab = .wallet
                    } else {
                        assetPath.append(route)
                    }
                } label: {
                    OathAssetTreeRow(entry: tree) {
                        OathHomeAssetRow(chain: chain, presentation: presentation,
                            balancesHidden: balancesHidden, showsSeparator: showsSeparator)
                            .equatable()
                    }
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier(item.reference == "native" ? "home.network.\(item.networkID)" : "home.token.\(item.assetID)")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !searching {
                        OathButton(feedback: nil) {
                            guard let walletID = session.portfolio?.wallet.id else { return }
                            Task {
                                await OathDiagnostics.$chain.withValue(item.networkID) {
                                    await OathDiagnostics.$operationID.withValue(UUID()) {
                                        do { try await session.setAssetHidden(true, assetID: item.assetID, walletID: walletID) }
                                        catch is CancellationError { /* Wallet switch or lock. */ }
                                        catch {
                                            OathDiagnostics.record(error, component: "asset_visibility", operation: "hide")
                                            walletActionFailed = true
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label(strings.text(.hideAsset), systemImage: "eye.slash")
                        }
                        .buttonStyle(.automatic)
                        .tint(.gray)
                        .accessibilityIdentifier("home.asset.hide")
                    }
                }
                .frame(maxWidth: searching ? .infinity : 700)
                .frame(maxWidth: .infinity)
                .background(Color.clear)
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
            formattingLocale: strings.language.locale.identifier,
            sortingLocale: strings.language.locale.identifier, hiddenAssetIDs: snapshot?.hiddenAssetIDs ?? [])
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

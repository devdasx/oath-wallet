import SwiftUI
import UIKit

struct WalletHomePortfolioView: View {
    private static let refreshIndicatorMinimumDuration: Duration =
        .milliseconds(2_600)

    let database: WalletDatabase
    let snapshot: WalletHomeSnapshot
    let walletAddress: String
    let capabilities: WalletCapabilities
    var permissionWalletID: String? = nil
    let preparation: WalletHomePortfolioPreparation?
    let onSend: () -> Void
    let onSendAsset: (WalletAsset) -> Void
    let onReceive: () -> Void
    let onScan: () -> Void
    let onPasteAddress: (String) -> Void
    let onScanAsset: (WalletAsset) -> Void
    let onPasteAsset: (WalletAsset, String) -> Void
    let onReceiveAsset: (WalletAsset) -> Void
    let onManageAssets: ([WalletAsset]) -> Void
    let onAssetVisibilityChanged: (WalletAsset, Bool) -> Void
    let onAssetPinChanged: (WalletAsset, Bool) -> Void
    let onShowAllActivity: ([WalletTransaction]) -> Void
    let onBalanceVisibilityChanged: (Bool) -> Void
    let onWalletActionsVisibilityChanged: (Bool) -> Void
    let onRefresh: () -> Void
    let isAppSwitcherPrivacyActive: Bool

    @Environment(\.scenePhase) private var permissionScenePhase
    @Environment(\.walletMultisigRestricted) private var multisigRestricted
    @Environment(\.stablecoinBlacklistFindings) private var blacklistFindings
    @State private var tronPermissionMonitor = TronPermissionMonitor()
    @State private var permissionRefreshID = UUID()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.walletCurrencyContext) private var currencyContext
    @Environment(WalletSettingsStore.self) private var applicationSettings
    @State private var trackedVisibility = WalletHomeTrackedVisibility()
    @State private var scrollThresholds =
        WalletHomeScrollVisibilityThresholds()

    var body: some View {
        walletContent(snapshot)
            .task(id: "stablecoin|\(permissionWalletID ?? "")|\(walletAddress)|\(permissionScenePhase)|\(permissionRefreshID)") {
                guard permissionScenePhase == .active, let permissionWalletID else { return }
                while !Task.isCancelled {
                    if await StablecoinBlacklistMonitor.shared.check(database: database, walletID: permissionWalletID) { return }
                    do { try await Task.sleep(for: .seconds(60)) }
                    catch { return }
                }
            }
            .task(id: "\(permissionWalletID ?? "")|\(walletAddress)|\(permissionScenePhase)|\(permissionRefreshID)") {
                guard permissionScenePhase == .active, let permissionWalletID else { return }
                while !Task.isCancelled {
                    let result = await tronPermissionMonitor.check(
                        database: database, displayedAddress: walletAddress,
                        expectedWalletID: permissionWalletID
                    )
                    guard !Task.isCancelled else { return }
                    if result?.showsWarning == true { return }
                    do { try await Task.sleep(for: .seconds(60)) }
                    catch { return }
                }
            }
    }

    private func walletContent(_ snapshot: WalletHomeSnapshot) -> some View {
        let resolution = WalletHomeAssetVisibility.resolution(
            walletAddress: walletAddress,
            preferencesJSON:
                applicationSettings.assetVisibilityPreferencesJSON
        )
        let currentAssets = capabilities.filteredAssets(snapshot.assets)
        let allAssets = preparation?.allAssets
            ?? capabilities.filteredAssets(
                WalletHomeAssetCatalog.availableAssets(
                    from: snapshot.assets
                )
            )
        let transactions = capabilities.filteredTransactions(
            snapshot.transactions
        )
        let visibilityCandidates = preparation.map {
            WalletHomePreparedAssetProjection.candidates(
                preparedVisibleAssets: $0.visibleHomeAssets,
                currentAssets: currentAssets
            )
        } ?? allAssets
        let visibleHomeAssets = WalletHomeAssetVisibility.homeAssets(
            from: visibilityCandidates,
            transactions: transactions,
            resolution: resolution
        )
        let pinnedAssets = visibleHomeAssets.filter {
            resolution.isPinned($0)
        }
        let regularAssets = visibleHomeAssets.filter {
            !resolution.isPinned($0)
        }
        let balanceRankedOrder = pinnedAssets.map {
            "pinned:\(AssetIdentityKey.canonical($0.id))"
        } + regularAssets.map {
            "regular:\(AssetIdentityKey.canonical($0.id))"
        }

        return List {
            Group {
                Section {
                    balanceSummary(snapshot)
                        .walletHomeMeasuredRowHeight { height in
                            scrollThresholds.recordBalanceHeight(height)
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)

                    walletActionsRow
                        .walletHomeMeasuredRowHeight { height in
                            scrollThresholds.recordActionsHeight(height)
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                }
                .walletZeroHorizontalListSectionMargins()

                if multisigRestricted || blacklistFindings.contains(where: { $0.walletID == permissionWalletID }) {
                    Section {
                        WalletAccountWarningRow(
                            hasTronMultisig: multisigRestricted,
                            findings: blacklistFindings.filter { $0.walletID == permissionWalletID }
                        )
                    }
                    .id("tron-permission-warning-" + (permissionWalletID ?? ""))
                }

                WalletMarketsSection(assets: capabilities.filteredAssets(visibleHomeAssets))

                if !pinnedAssets.isEmpty {
                    pinnedAssetsSection(
                        pinnedAssets,
                        allAssets: allAssets,
                        transactions: transactions,
                        showsManageAction: regularAssets.isEmpty
                    )
                }

                if !regularAssets.isEmpty || pinnedAssets.isEmpty {
                    assetsSection(
                        regularAssets,
                        allAssets: allAssets,
                        transactions: transactions
                    )
                }
                activitySection(transactions)
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        // Home owns one stationary, edge-to-edge background.
        .scrollContentBackground(.hidden)
        .animation(
            reduceMotion ? nil : .default,
            value: balanceRankedOrder
        )
        .refreshable {
            permissionRefreshID = UUID()
            onRefresh()
            try? await Task.sleep(
                for: Self.refreshIndicatorMinimumDuration
            )
        }
        .walletHomeScrollVisibility(
            thresholds: scrollThresholds
        ) { visibility in
            publishScrollVisibility(visibility)
        }
    }

    private func publishScrollVisibility(
        _ visibility: WalletHomeScrollVisibility
    ) {
        if trackedVisibility.recordBalance(visibility.balance) {
            onBalanceVisibilityChanged(visibility.balance)
        }
        if trackedVisibility.recordActions(visibility.actions) {
            onWalletActionsVisibilityChanged(visibility.actions)
        }
    }

    private func balanceSummary(
        _ snapshot: WalletHomeSnapshot
    ) -> some View {
        VStack(spacing: 8) {
            Text("wallet.home.balance.label")
                .font(.subheadline)
                .foregroundStyle(WalletTheme.secondaryLabel)
                .multilineTextAlignment(.center)

            Button(action: UniHaptic.action {
                UniHaptic.play(.toggle)
                applicationSettings.toggleBalancePrivacy()
            }) {
                WalletHeroCurrencyBalance(
                    usdValue: snapshot.totalBalance,
                    currencyContext: currencyContext,
                    isHidden: isBalanceHidden,
                    fontSize: 56,
                    minimumHeight: 68
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isBalanceHidden
                ? Text("wallet.home.balance.show.accessibility")
                : Text("wallet.home.balance.hide.accessibility"))
            .accessibilityValue(isBalanceHidden
                ? Text("wallet.home.balance.hidden")
                : Text(verbatim: EnglishNumbers.currency(
                    snapshot.totalBalance, using: currencyContext
                )))
            .accessibilityIdentifier("wallet-home-balance-value")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wallet-home-balance-summary")
    }

    private var walletActionsRow: some View {
        walletActions
            .padding(.top, 28)
            .frame(maxWidth: .infinity)
    }

    private var isBalanceHidden: Bool {
        applicationSettings.balancePrivacyEnabled
            || isAppSwitcherPrivacyActive
    }

    @ViewBuilder
    private var walletActions: some View {
        WalletPrimaryActionGroup {
            walletActionButtons
        }
    }

    @ViewBuilder
    private var walletActionButtons: some View {
        MutedWalletActionButton(
            title: "wallet.home.action.send",
            prominence: .primary,
            hapticPolicy: .silent,
            action: onSend
        )

        MutedWalletActionButton(
            title: "wallet.home.action.receive",
            prominence: .secondary,
            hapticPolicy: .silent,
            action: onReceive
        )

        WalletHomeMoreActionMenu(
            onScan: onScan,
            onPasteAddress: onPasteAddress
        )
    }

    private func assetsSection(
        _ assets: [WalletAsset],
        allAssets: [WalletAsset],
        transactions: [WalletTransaction]
    ) -> some View {
        Section {
            if assets.isEmpty {
                emptySection(
                    title: "wallet.home.empty.assets.title",
                    message: "wallet.home.empty.assets.message"
                )
            } else {
                ForEach(assets) { asset in
                    assetNavigationRow(
                        asset,
                        transactions: transactions,
                        assetIsPinned: false
                    )
                }
            }
        } header: {
            nativeSectionHeader(
                title: "wallet.home.assets.title",
                showsAction:
                    capabilities.showsAssetManagement
                        && !allAssets.isEmpty,
                actionAccessibilityLabel: "wallet.home.assets.see_all.accessibility",
                action: {
                    onManageAssets(allAssets)
                }
            )
        }
    }

    private func pinnedAssetsSection(
        _ assets: [WalletAsset],
        allAssets: [WalletAsset],
        transactions: [WalletTransaction],
        showsManageAction: Bool
    ) -> some View {
        Section {
            ForEach(assets) { asset in
                assetNavigationRow(
                    asset,
                    transactions: transactions,
                    assetIsPinned: true
                )
            }
        } header: {
            nativeSectionHeader(
                title: "wallet.home.assets.pinned.title",
                leadingSystemImage: "pin.fill",
                showsAction:
                    showsManageAction
                        && capabilities.showsAssetManagement
                        && !allAssets.isEmpty,
                actionAccessibilityLabel:
                    "wallet.home.assets.see_all.accessibility",
                action: {
                    onManageAssets(allAssets)
                }
            )
        }
    }

    private func assetNavigationRow(
        _ asset: WalletAsset,
        transactions: [WalletTransaction],
        assetIsPinned: Bool
    ) -> some View {
        NavigationLink {
            Group {
                WalletAssetDetailsView(
                    database: database,
                    asset: asset,
                    transactions: transactions,
                    isBalanceHidden: isBalanceHidden,
                    onSend: onSendAsset,
                    onReceive: {
                        onReceiveAsset(asset)
                    },
                    onScan: onScanAsset,
                    onPaste: onPasteAsset
                )
            }

        } label: {
            WalletAssetRow(
                asset: asset,
                isBalanceHidden: isBalanceHidden
            )
        }
        .accessibilityIdentifier("home.asset.\(AssetIdentityKey.canonical(asset.id))")
        .walletHomeAssetPinAction(isPinned: assetIsPinned) {
            onAssetPinChanged(asset, !assetIsPinned)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: UniHaptic.action {
                UniHaptic.play(.toggle)
                onAssetVisibilityChanged(asset, false)
            }) {
                Text("wallet.home.assets.hide.action")
            }
        }
    }

    @ViewBuilder
    private func activitySection(
        _ transactions: [WalletTransaction]
    ) -> some View {
        if !transactions.isEmpty {
            Section {
                ForEach(transactions.prefix(5)) { transaction in
                    NavigationLink {
                        Group {
                            WalletTransactionDetailsView(
                                transaction: transaction,
                                isBalanceHidden: isBalanceHidden
                            )
                        }

                    } label: {
                        WalletTransactionRow(
                            transaction: transaction,
                            isBalanceHidden: isBalanceHidden
                        )
                    }
                }
            } header: {
                nativeSectionHeader(
                    title: "wallet.home.activity.title",
                    showsAction: true,
                    actionAccessibilityLabel: "wallet.home.activity.see_all.accessibility",
                    action: {
                        onShowAllActivity(transactions)
                    }
                )
            }
        }
    }

    private func nativeSectionHeader(
        title: LocalizedStringKey,
        leadingSystemImage: String? = nil,
        showsAction: Bool,
        actionAccessibilityLabel: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .center, spacing: 6) {
                if let leadingSystemImage {
                    Image(systemName: leadingSystemImage)
                        .imageScale(.small)
                        .accessibilityHidden(true)
                }

                Text(title)
                    .accessibilityAddTraits(.isHeader)
            }

            Spacer(minLength: 8)

            if showsAction {
                Button("common.see_all", action: UniHaptic.action(nil, perform: action))
                    .buttonStyle(.plain)
                    .tint(WalletTheme.accent)
                    .accessibilityLabel(Text(actionAccessibilityLabel))
            }
        }
    }

    private func emptySection(
        title: LocalizedStringKey,
        message: LocalizedStringKey
    ) -> some View {
        WalletEmptyStateView(title, message: message)
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
    }

}

enum WalletHomeMoreAction: String, CaseIterable, Identifiable, Sendable {
    case scan
    case paste

    var id: String { rawValue }

    var localizationKey: String {
        switch self {
        case .scan:
            "wallet.home.action.scan_qr_code"
        case .paste:
            "common.paste"
        }
    }

    var localizedTitle: String {
        switch self {
        case .scan:
            WalletLocalization.string("wallet.home.action.scan_qr_code")
        case .paste:
            WalletLocalization.string("common.paste")
        }
    }
}

struct WalletHomeMoreActionMenu: View {
    let onScan: () -> Void
    let onPasteAddress: (String) -> Void

    var body: some View {
        Menu {
            ForEach(WalletHomeMoreAction.allCases) { action in
                Section {
                    Button(action: UniHaptic.action(nil) {
                        activate(action)
                    }) {
                        Text(action.localizedTitle)
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.headline)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Circle())
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .foregroundStyle(WalletTheme.primaryLabel)
        .fixedSize()
        .walletRegularGlassEffect(
            interactive: true,
            in: Circle()
        )
        .buttonBorderShape(.circle)
        .accessibilityLabel(Text("wallet.home.action.more"))
        .walletTransferAction()
    }

    @MainActor
    private func activate(_ action: WalletHomeMoreAction) {
        switch action {
        case .scan:
            activate(action: onScan)
        case .paste:
            activate {
                onPasteAddress(UIPasteboard.general.string ?? "")
            }
        }
    }

    @MainActor
    private func activate(
        action: () -> Void
    ) {
        action()
    }
}

struct WalletPrimaryActionGroup<Actions: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let actions: Actions

    init(@ViewBuilder actions: () -> Actions) {
        self.actions = actions()
    }

    var body: some View {
        WalletGlassEffectContainer(spacing: 0) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 12) {
                    actions
                }
            } else {
                HStack(spacing: 12) {
                    actions
                }
            }
        }
        .walletActionScreenMargins()
        .walletTransferAction()
    }
}

extension View {
    func walletHomeMeasuredRowHeight(
        _ action: @escaping (CGFloat) -> Void
    ) -> some View {
        onGeometryChange(
            for: CGFloat.self,
            of: { proxy in
                WalletHomeScrollVisibilityThresholds.normalizedHeight(
                    proxy.size.height
                )
            },
            action: action
        )
    }

    func walletHomeScrollVisibility(
        thresholds: WalletHomeScrollVisibilityThresholds,
        _ action: @escaping (WalletHomeScrollVisibility) -> Void
    ) -> some View {
        onScrollGeometryChange(
            for: WalletHomeScrollVisibility.self,
            of: { geometry in
                WalletHomeScrollVisibilityPolicy.visibility(
                    contentOffsetY: geometry.contentOffset.y,
                    contentInsetTop: geometry.contentInsets.top,
                    thresholds: thresholds
                )
            },
            action: { _, visibility in
                action(visibility)
            }
        )
    }
}

struct WalletHomeScrollVisibility: Equatable, Sendable {
    let balance: Bool
    let actions: Bool

    static let allVisible = WalletHomeScrollVisibility(
        balance: true,
        actions: true
    )
}

struct WalletHomeScrollVisibilityThresholds: Equatable, Sendable {
    private(set) var balanceHeight: CGFloat = 0
    private(set) var actionsHeight: CGFloat = 0

    var isReady: Bool {
        balanceHeight > 0 && actionsHeight > 0
    }

    var balanceBottom: CGFloat {
        balanceHeight
    }

    var actionsBottom: CGFloat {
        balanceHeight + actionsHeight
    }

    mutating func recordBalanceHeight(_ height: CGFloat) {
        balanceHeight = Self.normalizedHeight(height)
    }

    mutating func recordActionsHeight(_ height: CGFloat) {
        actionsHeight = Self.normalizedHeight(height)
    }

    static func normalizedHeight(_ height: CGFloat) -> CGFloat {
        guard height.isFinite else { return 0 }
        return (max(0, height) * 2).rounded() / 2
    }
}

enum WalletHomeScrollVisibilityPolicy {
    static func visibility(
        contentOffsetY: CGFloat,
        contentInsetTop: CGFloat,
        thresholds: WalletHomeScrollVisibilityThresholds
    ) -> WalletHomeScrollVisibility {
        guard thresholds.isReady else { return .allVisible }
        let visibleContentTop = max(
            0,
            contentOffsetY + contentInsetTop
        )
        return WalletHomeScrollVisibility(
            balance: visibleContentTop < thresholds.balanceBottom,
            actions: visibleContentTop < thresholds.actionsBottom
        )
    }
}

struct WalletHomeTrackedVisibility: Equatable, Sendable {
    private(set) var balance: Bool?
    private(set) var actions: Bool?

    mutating func recordBalance(_ isVisible: Bool) -> Bool {
        guard balance != isVisible else { return false }
        balance = isVisible
        return true
    }

    mutating func recordActions(_ isVisible: Bool) -> Bool {
        guard actions != isVisible else { return false }
        actions = isVisible
        return true
    }
}

enum WalletHomePreparedAssetProjection {
    static func candidates(
        preparedVisibleAssets: [WalletAsset],
        currentAssets: [WalletAsset]
    ) -> [WalletAsset] {
        WalletAssetBalanceSnapshot(assets: currentAssets).projecting(
            candidates: preparedVisibleAssets
        )
    }
}

import Foundation
import Observation
import os
import GRDB
import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor
@Suite(.serialized)
struct NetworkSelectionChipAppearanceTests {
    @Test
    func networkSelectorStaysAtTheTopOfATallSafeAreaInset() throws {
        let controller = UIHostingController(
            rootView: Color.clear
                .safeAreaInset(edge: .top, spacing: 0) {
                    AssetNetworkSelector(
                        options: Array(
                            AssetNetworkSelectorOption.allSupported.prefix(4)
                        ),
                        selectedNetworkID: .constant(nil),
                        presentation: .liquidGlass
                    )
                }
                .environment(\.dynamicTypeSize, .large)
        )
        let windowScene = try #require(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(
            origin: .zero,
            size: CGSize(width: 390, height: 700)
        )
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()

        let selectorScrollView = try #require(
            descendants(of: UIScrollView.self, in: controller.view).first
        )
        // UIKit may include the mounted scene's top safe-area contribution in
        // this scroll view's frame. It must still stay in the compact top
        // region instead of expanding through the 700-point proposal.
        #expect(selectorScrollView.frame.minY < 160)
        #expect(selectorScrollView.frame.height >= 22)
        #expect(selectorScrollView.frame.height < 180)
        #expect(selectorScrollView.frame.maxY < 240)
    }

    @Test(arguments: NativeListTestLayout.allCases, [false, true])
    func networkBarKeepsControlsClearOfNavigationAndList(
        layout: NativeListTestLayout, inSheet: Bool
    ) async throws {
        let database = try WalletDatabase.temporary()
        var preferences = WalletApplicationSettings.default
        preferences.languageIdentifier = layout.direction == .rightToLeft ? "ar" : "en"
        let settings = WalletSettingsStore(database: database, initialSettings: preferences)
        let options = Array(AssetNetworkSelectorOption.allSupported.prefix(4))
        let navigationContent = NavigationStack {
            List {
                Section("receive.section.assets") {
                    ForEach(0..<40) { index in
                        Text(verbatim: "Asset \(index)")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("receive.title")
            .navigationBarTitleDisplayMode(.inline)
            .assetNetworkAppBar(
                isPresented: true,
                options: options,
                selectedNetworkID: .constant(nil)
            )
            .searchable(text: .constant(""), placement: .toolbar,
                        prompt: Text("receive.search.prompt"))
            .walletAutomaticSearchToolbarBehavior()
        }
        let host = try NativeListTestHost(layout: layout) {
            Group {
                if inSheet {
                    Color.clear.sheet(isPresented: .constant(true)) {
                        navigationContent
                            .walletSheetBackground()
                            .presentationDetents([.large])
                            .presentationDragIndicator(.visible)
                    }
                } else {
                    navigationContent
                }
            }
            .environment(settings)
        }
        defer { host.close() }
        let window = try #require(host.rootView.window)
        let root = inSheet ? window : host.rootView
        try await SendEntryUIProbe.wait(in: root) {
            descendants(of: UICollectionView.self, in: root).contains {
                $0.numberOfSections > 0 && $0.numberOfItems(inSection: 0) > 0
            }
        }
        let list = try #require(descendants(of: UICollectionView.self, in: root).first {
            $0.numberOfSections > 0 && $0.numberOfItems(inSection: 0) > 0
        })
        let navigationBar = try #require(descendants(of: UINavigationBar.self, in: root).first)
        let selector = try #require(
            descendants(of: UIScrollView.self, in: root)
                .first { !($0 is UICollectionView) }
        )
        // The native scroll container extends through the top safe area.
        // Its safe-area layout guide describes the usable chip viewport.
        // Creating rows precedes the navigation bar's final inline layout.
        // Wait for stable public geometry rather than sampling that transition.
        var lastFrames: [CGRect] = []
        var stablePasses = 0
        try await SendEntryUIProbe.wait(in: root) {
            let frames = [
                navigationBar.convert(navigationBar.bounds, to: window.screen.coordinateSpace),
                selector.convert(selector.safeAreaLayoutGuide.layoutFrame, to: window.screen.coordinateSpace)
            ]
            if frames == lastFrames {
                stablePasses += 1
            } else {
                lastFrames = frames
                stablePasses = 0
            }
            return stablePasses >= 3 && navigationBar.topItem?.largeTitleDisplayMode == .never
        }
        let barFrame = navigationBar.convert(navigationBar.bounds, to: window.screen.coordinateSpace)
        let buttonFrame = selector.convert(selector.safeAreaLayoutGuide.layoutFrame, to: window.screen.coordinateSpace)
        let clearance = buttonFrame.minY - barFrame.maxY
        let pixel = 1 / window.screen.scale
        #expect(abs(clearance) <= pixel,
            "No extra gap above the chips; gap: \(clearance), controls: \(buttonFrame), bar: \(barFrame)")
        #expect(buttonFrame.height >= 44)
        #expect(abs(buttonFrame.height - selector.contentSize.height) <= pixel,
            "The viewport must fit the native content without extra vertical space")
        let firstCell = try #require(list.cellForItem(at: IndexPath(item: 0, section: 0)))
        let cellFrame = firstCell.convert(firstCell.bounds, to: window.screen.coordinateSpace)
        #expect(cellFrame.minY >= buttonFrame.maxY + 8 - pixel)
        #expect(cellFrame.maxY <= window.screen.coordinateSpace.bounds.maxY)

        // The filter remains usable while assets scroll underneath its bar.
        list.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
        root.layoutIfNeeded()
        await Task.yield()
        #expect(abs(selector.convert(selector.safeAreaLayoutGuide.layoutFrame, to: window.screen.coordinateSpace).minY - buttonFrame.minY) < 1)
    }

    @Test
    func nativeReceiveVariantsUseCoinIdentityNotNetworkIdentity() {
        for network in ReceiveNetworkCatalog.all {
            let variant = ReceiveToken.nativeAsset(for: network)
                .variants[0]
            #expect(
                variant.logoSource == .nativeCoin(
                    blockchain: network.blockchain
                )
            )
        }
    }

    private func descendants<ViewType: UIView>(
        of type: ViewType.Type,
        in view: UIView
    ) -> [ViewType] {
        view.subviews.flatMap { child in
            var result = descendants(of: type, in: child)
            if let match = child as? ViewType {
                result.insert(match, at: 0)
            }
            return result
        }
    }
}

struct WalletAssetListBalancePresentationTests {
    @Test(arguments: [
        ("5.515555838897961624934314", "5.515555838898"),
        ("9.9999999999999", "10"),
        ("0.00000000000049", "0"),
        ("123.45", "123.45")
    ])
    func listBalanceUsesAtMostTwelveFractionDigits(
        input: String,
        expected: String
    ) {
        let asset = WalletAsset(
            id: "near:native",
            name: "NEAR",
            symbol: "NEAR",
            logoSource: .unavailable,
            network: .near,
            balance: 0,
            fiatValue: 0,
            balanceText: input
        )

        #expect(asset.listDisplayBalanceText == expected)
        #expect(asset.displayBalanceText == input)
    }

    @Test
    func nativeAssetsReplacePersistedNamesWithCanonicalLocalizedNames() {
        let cases: [(WalletBlockchain, String)] = [
            (.aptos, "asset.aptos.name"),
            (.stellar, "asset.stellar_lumen.name"),
            (.near, "asset.near.name"),
            (.xrp, "asset.xrp.name"),
            (.sui, "asset.sui.name"),
            (.ton, "asset.gram.name"),
            (.tron, "network.tron.name"),
            (.solana, "network.solana.name"),
            (.bitcoin, "network.bitcoin.name"),
            (.bitcoincash, "network.bitcoin_cash.name"),
            (.litecoin, "network.litecoin.name"),
            (.dogecoin, "network.dogecoin.name"),
            (.ethereum, "network.ethereum"),
            (.smartchain, "network.bnb_smart_chain"),
            (.polygon, "network.polygon"),
            (.arbitrum, "network.arbitrum"),
            (.avalanchec, "network.avalanche"),
            (.optimism, "network.optimism"),
            (.base, "network.base"),
            (.xdai, "network.gnosis"),
            (.scroll, "network.scroll"),
            (.linea, "network.linea"),
            (.taiko, "network.taiko"),
            (.telos, "network.telos"),
            (.xlayer, "network.x_layer"),
            (.arc, "network.arc")
        ]

        for (blockchain, key) in cases {
            let asset = WalletAsset(
                id: "\(blockchain.rawValue):native",
                name: "Persisted Legacy Name (OLD)",
                symbol: "OLD",
                logoSource: .nativeCoin(blockchain: blockchain),
                network: blockchain,
                balance: 0,
                fiatValue: 0
            )
            #expect(asset.name == WalletLocalization.string(key))
        }
    }

    @Test
    func tokenAssetsPreserveTheirCatalogName() {
        let asset = WalletAsset(
            id: "ethereum:usdc",
            name: "USD Coin",
            symbol: "USDC",
            logoSource: .catalogToken(
                blockchain: .ethereum,
                contractAddress: "0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
                logoURL: nil
            ),
            network: .ethereum,
            balance: 0,
            fiatValue: 0
        )

        #expect(asset.name == "USD Coin")
    }
}

@Suite(.serialized)
struct WalletAppearanceTests {
    @Test
    func walletSwitcherRoutesOnlyInfoTargetToSettings() {
        #expect(
            WalletSwitcherRowInteractionPolicy.action(for: .content)
                == .activateWallet
        )
        #expect(
            WalletSwitcherRowInteractionPolicy.action(for: .information)
                == .openWalletSettings
        )
    }

    @Test
    func selectionBadgeRequiresMultipleWallets() {
        #expect(
            !WalletSelectionBadgePolicy.shouldShow(
                isSelected: true,
                walletCount: 1
            )
        )
        #expect(
            WalletSelectionBadgePolicy.shouldShow(
                isSelected: true,
                walletCount: 2
            )
        )
        #expect(
            !WalletSelectionBadgePolicy.shouldShow(
                isSelected: false,
                walletCount: 2
            )
        )
    }

    @Test
    func assignmentUsesEveryPaletteColorBeforeRepeating() {
        var assignedIDs: [String] = []

        for _ in WalletAppearanceColor.allCases {
            let color = WalletAppearanceColor.nextAvailable(
                existingIDs: assignedIDs,
                randomIndex: { _ in 0 }
            )
            assignedIDs.append(color.rawValue)
        }

        #expect(
            Set(assignedIDs).count
                == WalletAppearanceColor.allCases.count
        )
    }

    @Test
    func migrationBackfillsDistinctPersistedColors() throws {
        let queue = try DatabaseQueue()
        try WalletDatabase.migrator.migrate(
            queue,
            upTo: "v39_provider_endpoint_health"
        )
        try queue.write { database in
            try database.execute(
                sql: """
                INSERT INTO profiles (
                    id, displayName, createdAt, updatedAt, lastActiveAt
                ) VALUES (?, NULL, 1, 1, 1)
                """,
                arguments: [WalletDatabase.defaultProfileID]
            )
            for index in 0..<3 {
                try database.execute(
                    sql: """
                    INSERT INTO wallets (
                        id, profileID, name, kind, isSelected,
                        sortOrder, createdAt, updatedAt
                    ) VALUES (?, ?, ?, 'created', ?, ?, ?, ?)
                    """,
                    arguments: [
                        "wallet-\(index)",
                        WalletDatabase.defaultProfileID,
                        "Wallet \(index)",
                        index == 0,
                        index,
                        Double(index + 1),
                        Double(index + 1)
                    ]
                )
            }
        }

        try WalletDatabase.migrator.migrate(queue)

        let storedIDs = try queue.read { database in
            try String.fetchAll(
                database,
                sql: """
                SELECT appearanceColorID
                FROM wallets
                ORDER BY sortOrder
                """
            )
        }
        #expect(storedIDs.count == 3)
        #expect(Set(storedIDs).count == 3)
        #expect(
            storedIDs.allSatisfy {
                WalletAppearanceColor(rawValue: $0) != nil
            }
        )
    }

    @Test
    func colorChangePersistsThroughManagedWalletReload() async throws {
        let database = try WalletDatabase.temporary()
        let now = Date().timeIntervalSince1970
        try await database.pool.write { storage in
            try DBWalletRecord(
                id: "appearance-wallet",
                profileID: WalletDatabase.defaultProfileID,
                name: "Appearance Wallet",
                kind: DatabaseWalletKind.created.rawValue,
                secretKeyReference: nil,
                isSelected: true,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: now,
                archivedAt: nil,
                appearanceColorID: WalletAppearanceColor.blue.rawValue
            ).insert(storage)
        }

        let updated = try await database.setWalletAppearanceColor(
            walletID: "appearance-wallet",
            color: .purple
        )
        let reloaded = try await database.managedWallet(
            walletID: "appearance-wallet"
        )

        #expect(updated.appearanceColor == .purple)
        #expect(reloaded.appearanceColor == .purple)
    }

    @Test
    func activeWalletColorUpdatesOnlyForTheMatchingWallet() throws {
        let context = AppRootResolvedWalletContext(
            requestID: UUID(),
            identity: PersistedWalletIdentity(
                walletID: "active-wallet",
                address: "0x1111111111111111111111111111111111111111"
            ),
            name: "Active Wallet",
            capabilities: .fullWallet,
            appearanceColor: .purple
        )
        let presentation = AppRootWalletPresentation.resolved(
            context: context,
            state: .loading
        )

        #expect(presentation.appearanceColor == .purple)
        #expect(
            presentation.replacingAppearanceColor(
                .orange,
                matchingWalletID: "another-wallet"
            ) == nil
        )

        let recolored = try #require(
            presentation.replacingAppearanceColor(
                .orange,
                matchingWalletID: "active-wallet"
            )
        )
        #expect(recolored.appearanceColor == .orange)
        #expect(recolored.resolvedContext?.appearanceColor == .orange)
    }

    @Test
    func progressiveRefreshDoesNotRevertTheActiveWalletColor() throws {
        let loadContext = AppRootResolvedWalletContext(
            requestID: UUID(),
            identity: PersistedWalletIdentity(
                walletID: "refreshing-wallet",
                address: "0x2222222222222222222222222222222222222222"
            ),
            name: "Refreshing Wallet",
            capabilities: .fullWallet,
            appearanceColor: .blue
        )
        var presentation = AppRootWalletPresentation.resolved(
            context: loadContext,
            state: .loading
        )
        presentation = try #require(
            presentation.replacingAppearanceColor(
                .cyan,
                matchingWalletID: "refreshing-wallet"
            )
        )
        presentation = try #require(
            presentation.replacingState(
                .content(.empty),
                for: loadContext
            )
        )

        #expect(presentation.appearanceColor == .cyan)
        #expect(presentation.resolvedContext?.appearanceColor == .cyan)
    }

    @Test
    func animatedBalanceSeparatesFractionalCurrencyDigits() {
        let presentation = WalletCurrencyBalancePresentation(
            formatted: "$255.66",
            animationValue: 255.66
        )

        #expect(presentation.primaryLeading == "$255")
        #expect(presentation.secondaryFraction == ".66")
        #expect(presentation.primaryTrailing.isEmpty)
    }

    @Test
    func animatedBalancePreservesSuffixesOutsideTheGrayFraction() {
        let presentation = WalletCurrencyBalancePresentation(
            formatted: "255.66 USD",
            animationValue: 255.66
        )

        #expect(presentation.primaryLeading == "255")
        #expect(presentation.secondaryFraction == ".66")
        #expect(presentation.primaryTrailing == " USD")
    }

    @Test
    func animatedBalanceUsesConvertedValueForCountingDirection() {
        let presentation = WalletCurrencyBalancePresentation(
            usdValue: 125.25,
            currencyContext: WalletCurrencyContext(
                code: "EUR",
                ratePerUSD: 2
            )
        )

        #expect(presentation.animationValue == 250.5)
        #expect(presentation.secondaryFraction == ".50")
    }

    @Test
    func hiddenBalanceUsesOneGrayRoleForEverySegment() {
        let colors = WalletCurrencyBalanceColorPlan(isHidden: true)

        #expect(colors.leading == .gray)
        #expect(colors.fraction == .gray)
        #expect(colors.trailing == .gray)
    }

    @Test
    func visibleBalanceUsesPrimaryColorForEverySegment() {
        let colors = WalletCurrencyBalanceColorPlan(isHidden: false)

        #expect(colors.leading == .primary)
        #expect(colors.fraction == .primary)
        #expect(colors.trailing == .primary)
    }

    @Test
    func hiddenBalanceBypassesAnimatedValueRendering() {
        #expect(
            WalletCurrencyBalanceDisplayMode(isHidden: true)
                == .staticPrivacyPlaceholder
        )
        #expect(
            WalletCurrencyBalanceDisplayMode(isHidden: false)
                == .animatedValue
        )
    }

    @Test
    func backupWarningReflectsManualAndCloudVerification() {
        let createdWallet = makeWallet(
            kind: .created,
            backupState: .notVerified,
            iCloudBackupUpdatedAt: nil
        )
        let manuallyBackedUpWallet = makeWallet(
            kind: .created,
            backupState: .verified,
            iCloudBackupUpdatedAt: nil
        )
        let cloudBackedUpWallet = makeWallet(
            kind: .created,
            backupState: .notVerified,
            iCloudBackupUpdatedAt: Date()
        )
        let watchOnlyWallet = makeWallet(
            kind: .watchOnly,
            backupState: .notVerified,
            iCloudBackupUpdatedAt: nil
        )

        #expect(createdWallet.needsBackup)
        #expect(!manuallyBackedUpWallet.needsBackup)
        #expect(!cloudBackedUpWallet.needsBackup)
        #expect(!watchOnlyWallet.needsBackup)
    }

    private func makeWallet(
        kind: ManagedWalletKind,
        backupState: DatabaseWalletBackupState,
        iCloudBackupUpdatedAt: Date?
    ) -> ManagedWallet {
        ManagedWallet(
            id: UUID().uuidString,
            name: "Wallet",
            kind: kind,
            address: "",
            fiatUSDBalance: 0,
            isSelected: false,
            notificationsEnabledWhenInactive: false,
            backupState: backupState,
            backupVerifiedAt: nil,
            iCloudBackupUpdatedAt: iCloudBackupUpdatedAt,
            mnemonicWordCount: nil,
            createdAt: Date(timeIntervalSince1970: 1)
        )
    }
}

@MainActor
@Suite(.serialized)
struct WalletHeroBalanceLayoutTests {
    @Test(arguments: [NativeListTestLayout.phone, .phoneLandscape, .pad, .largeTextRTL])
    func largeAmountsFitThePaddedWidthWithoutTruncation(
        layout: NativeListTestLayout
    ) async throws {
        let measurements = HeroBalanceTextMeasurements()
        let model = HeroBalanceTestModel()
        let width = min(layout.size.width, 744)
        let host = try NativeListTestHost(layout: layout) {
            HeroBalanceMeasurementHarness(model: model, measurements: measurements, width: width)
        }
        defer { host.close() }
        _ = try await host.list()
        try await SendEntryUIProbe.wait(in: host.rootView) { measurements.latest != nil }
        let small = try #require(measurements.latest)

        for amount in ["211656098495.01", "999999999999999999999999.99"] {
            measurements.clear()
            model.amount = try #require(Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")))
            try await SendEntryUIProbe.wait(in: host.rootView) { measurements.latest != nil }
            // Let the native numeric transition finish before measuring its final layout.
            try await Task.sleep(for: .milliseconds(400))
            let large = try #require(measurements.latest)
            #expect(!large.isTruncated)
            #expect(large.lineCount == 1)
            #expect(large.width <= width - 40 + 1)
            #expect(large.height <= small.height + 1)
            if amount.hasPrefix("999") { #expect(large.height < small.height) }
        }
        measurements.clear()
        model.amount = 1
        try await SendEntryUIProbe.wait(in: host.rootView) { measurements.latest != nil }
        try await Task.sleep(for: .milliseconds(400))
        let restored = try #require(measurements.latest)
        #expect(!restored.isTruncated)
        #expect(abs(restored.height - small.height) < 1)
    }
}

private struct HeroBalanceMeasurementHarness: View {
    let model: HeroBalanceTestModel
    let measurements: HeroBalanceTextMeasurements
    let width: CGFloat

    var body: some View {
        List {
            WalletHeroCurrencyBalance(
                usdValue: model.amount,
                currencyContext: WalletCurrencyContext(code: "IRR", ratePerUSD: 1),
                isHidden: false, fontSize: 56, minimumHeight: 68
            )
            .textRenderer(HeroBalanceMeasurementRenderer(measurements: measurements))
            .padding(.horizontal, 20)
            .listRowInsets(EdgeInsets())
        }
        .listStyle(.plain)
        .frame(width: width)
    }
}

@MainActor
@Observable
private final class HeroBalanceTestModel {
    var amount: Decimal = 1
}

private struct HeroBalanceTextMeasurement: Sendable {
    let width: CGFloat
    let height: CGFloat
    let lineCount: Int
    let isTruncated: Bool
}

private final class HeroBalanceTextMeasurements: Sendable {
    private let value = OSAllocatedUnfairLock<(latest: HeroBalanceTextMeasurement?, maximumWidth: CGFloat)>(
        initialState: (nil, 0)
    )
    var latest: HeroBalanceTextMeasurement? { value.withLock { $0.latest } }
    var maximumWidth: CGFloat { value.withLock { $0.maximumWidth } }
    func clear() { value.withLock { $0 = (nil, 0) } }
    func record(_ measurement: HeroBalanceTextMeasurement) {
        value.withLock {
            $0.latest = measurement
            $0.maximumWidth = max($0.maximumWidth, measurement.width)
        }
    }
}

/// Reads SwiftUI's actual text layout without taking or storing screenshots.
private struct HeroBalanceMeasurementRenderer: TextRenderer {
    let measurements: HeroBalanceTextMeasurements

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let bounds = layout.reduce(CGRect.null) {
            $0.union($1.typographicBounds.rect.applying(context.transform))
        }
        measurements.record(HeroBalanceTextMeasurement(
            width: bounds.width, height: bounds.height,
            lineCount: layout.count, isTruncated: layout.isTruncated
        ))
        for line in layout { context.draw(line) }
    }
}

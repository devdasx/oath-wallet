import SwiftUI
import Testing
import UIKit
import Observation
import GRDB
@testable import Aperture

@Suite("Wallet home activity copy")
struct WalletHomeActivityCopyTests {
    @Test
    func rowsUseConciseDirectionAndRelativeDayLabels() {
        #expect(
            WalletLocalization.string(
                "wallet.transaction.details.direction.received"
            ) == "Received"
        )
        #expect(
            WalletLocalization.string(
                "wallet.transaction.details.direction.sent"
            ) == "Sent"
        )
        #expect(
            WalletLocalization.string(
                "wallet.activity.day.today"
            ) == "Today"
        )
        #expect(
            WalletLocalization.string(
                "wallet.activity.day.yesterday"
            ) == "Yesterday"
        )
    }

    @Test
    func pinnedSectionUsesConciseAssetLabel() {
        #expect(
            WalletLocalization.string(
                "wallet.home.assets.pinned.title"
            ) == "Pinned Assets"
        )
    }

    @Test
    func relativeActivityTimestampsUseAtAndTwelveHourTime() {
        #expect(
            EnglishNumbers.localized(
                "wallet.activity.time.today",
                "9:41 AM"
            ) == "Today at 9:41 AM"
        )
        #expect(
            EnglishNumbers.localized(
                "wallet.activity.time.yesterday",
                "6:24 PM"
            ) == "Yesterday at 6:24 PM"
        )
    }

    @Test
    func activityTimestampKeepsTimeOnlyForRelativeDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 30,
                    hour: 12
                )
            )
        )
        let today = try #require(
            calendar.date(byAdding: .hour, value: -2, to: now)
        )
        let yesterday = try #require(
            calendar.date(byAdding: .hour, value: -14, to: now)
        )
        let older = try #require(
            calendar.date(byAdding: .day, value: -2, to: now)
        )

        #expect(
            EnglishNumbers.walletActivityTimestamp(
                today,
                relativeTo: now
            ) == "Today at 10:00 AM"
        )
        #expect(
            EnglishNumbers.walletActivityTimestamp(
                yesterday,
                relativeTo: now
            ) == "Yesterday at 10:00 PM"
        )
        #expect(
            EnglishNumbers.walletActivityTimestamp(
                older,
                relativeTo: now
            ) == EnglishNumbers.walletActivityDay(older, relativeTo: now)
        )
    }
}

@Suite("Wallet home quick actions")
struct WalletHomeQuickActionsTests {
    @Test
    func menuUsesTheRequestedStableOrder() {
        #expect(
            WalletHomeQuickAction.allCases == [
                .currency,
                .security,
                .backupAndKeys,
                .settings,
            ]
        )
    }

    @Test
    func menuUsesTheRequestedNativeSymbols() {
        #expect(WalletHomeQuickAction.currency.systemImage == "globe")
        #expect(WalletHomeQuickAction.security.systemImage == "faceid")
        #expect(
            WalletHomeQuickAction.backupAndKeys.systemImage
                == "externaldrive.badge.icloud"
        )
        #expect(WalletHomeQuickAction.settings.systemImage == "gearshape")
    }
}

@Suite("Backup and keys shortcut policy")
struct SettingsBackupAndKeysPolicyTests {
    @Test
    func onlySoftwareWalletsWithExportableSecretsAreIncluded() {
        #expect(SettingsBackupAndKeysPolicy.includes(.created))
        #expect(SettingsBackupAndKeysPolicy.includes(.importedRecoveryPhrase))
        #expect(SettingsBackupAndKeysPolicy.includes(.importedPrivateKey))
        #expect(!SettingsBackupAndKeysPolicy.includes(.watchOnly))
        #expect(!SettingsBackupAndKeysPolicy.includes(.hardware))
    }

    @Test
    func recoveryWalletsOfferPhraseAndKeys() {
        #expect(
            SettingsBackupAndKeysPolicy.materialChoices(for: .created)
                == [.recoveryPhrase, .privateKeys]
        )
        #expect(
            SettingsBackupAndKeysPolicy.materialChoices(
                for: .importedRecoveryPhrase
            ) == [.recoveryPhrase, .privateKeys]
        )
    }

    @Test
    func privateKeyImportsOfferOnlyTheirPrivateKey() {
        #expect(
            SettingsBackupAndKeysPolicy.materialChoices(
                for: .importedPrivateKey
            ) == [.privateKeys]
        )
    }

    @Test
    func onlyRecoveryPhrasesOfferBackupMethodSelection() {
        for kind in [
            ManagedWalletKind.created,
            .importedRecoveryPhrase,
            .importedPrivateKey,
            .watchOnly,
            .hardware,
        ] {
            #expect(SettingsBackupAndKeysPolicy.methodChoices(
                for: kind, material: .privateKeys
            ).isEmpty)
            #expect(SettingsBackupAndKeysPolicy.methodChoices(
                for: kind, material: .recoveryPhrase
            ) == (kind.hasRecoveryPhrase ? [.manual, .iCloud] : []))
        }
    }

}

@Suite("Wallet transaction details copy")
struct WalletTransactionDetailsCopyTests {
    @Test
    func transferRowsUseConciseLabels() {
        #expect(
            WalletLocalization.string(
                "wallet.transaction.details.local_value"
            ) == "Value"
        )
        #expect(
            WalletLocalization.string(
                "wallet.transaction.details.asset"
            ) == "Network"
        )
        #expect(
            WalletLocalization.string(
                "wallet.transaction.details.date"
            ) == "Time"
        )
    }
}

@Suite("Wallet home top-toolbar layout", .serialized)
struct WalletHomeTopToolbarLayoutTests {
    @Test
    func homeCurrencyConverterUsesOnlyTheLargeSheetDetent() {
        #expect(
            HomeCurrencyConverterSheetDetentPolicy.allowedDetents == [.large]
        )
        #expect(
            !HomeCurrencyConverterSheetDetentPolicy.allowedDetents
                .contains(.medium)
        )
    }

    @Test
    func titleWidthReservesSpaceForEveryNativeToolbarControl() {
        let expectations: [(container: CGFloat, title: CGFloat)] = [
            (320, 96),
            (393, 169),
            (440, 216),
            (600, 320),
            (1_024, 320)
        ]

        for expectation in expectations {
            #expect(
                WalletHomeTopToolbarLayout
                    .switcherTitleMaximumWidth(
                        containerWidth: expectation.container
                    ) == expectation.title
            )
        }
    }

    @Test
    func titleWidthReservesAdditionalSpaceForConverterShortcut() {
        let expectations: [(container: CGFloat, title: CGFloat)] = [
            (320, 44),
            (393, 117),
            (440, 164),
            (600, 320),
            (1_024, 320)
        ]

        for expectation in expectations {
            #expect(
                WalletHomeTopToolbarLayout
                    .switcherTitleMaximumWidth(
                        containerWidth: expectation.container,
                        showsCurrencyConverterShortcut: true
                    ) == expectation.title
            )
        }
    }

    @Test
    @MainActor
    func longMixedDirectionNameHasABoundedSwiftUILayout() {
        let containerWidth: CGFloat = 393
        let maximumTitleWidth = WalletHomeTopToolbarLayout
            .switcherTitleMaximumWidth(
                containerWidth: containerWidth
            )
        let host = UIHostingController(
            rootView: WalletHomeWalletSwitcherToolbarLabel(
                color: .red,
                maximumTitleWidth: maximumTitleWidth
            ) {
                Text(
                    verbatim:
                        "محفظة مستوردة njjjjsjsjsjsjsjjsjsjsjsjsjsjsjsk"
                )
                .font(.headline)
            }
        )

        let size = host.sizeThatFits(
            in: CGSize(width: 1_000, height: 100)
        )

        #expect(size.width > WalletHomeTopToolbarLayout.walletIdentityWidth)
        #expect(
            size.width
                <= maximumTitleWidth
                    + WalletHomeTopToolbarLayout.walletIdentityWidth
                    + 0.5
        )
        #expect(size.height <= 44)
    }

    @Test
    @MainActor
    func longMixedDirectionNameRemainsBoundedForRTLAccessibilityText() {
        let containerWidth: CGFloat = 320
        let maximumTitleWidth = WalletHomeTopToolbarLayout
            .switcherTitleMaximumWidth(
                containerWidth: containerWidth
            )
        let host = UIHostingController(
            rootView: WalletHomeWalletSwitcherToolbarLabel(
                color: .red,
                maximumTitleWidth: maximumTitleWidth
            ) {
                Text(
                    verbatim:
                        "محفظة مستوردة njjjjsjsjsjsjsjjsjsjsjsjsjsjsjsk"
                )
                .font(.headline)
            }
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.dynamicTypeSize, .accessibility3)
        )

        let size = host.sizeThatFits(
            in: CGSize(width: 1_000, height: 200)
        )

        #expect(size.width > WalletHomeTopToolbarLayout.walletIdentityWidth)
        #expect(
            size.width
                <= maximumTitleWidth
                    + WalletHomeTopToolbarLayout.walletIdentityWidth
                    + 0.5
        )
        #expect(size.height <= 60)
    }

    @Test @MainActor
    func nativeToolbarKeepsLongNameSwitcherVisibleAtMinimumWidth() async throws {
        try await verifyNativeToolbarKeepsSwitcherVisible(
            rootView: WalletHomeToolbarCollisionHarness(containerWidth: 320),
            size: CGSize(width: 320, height: 844)
        )
    }

    @Test @MainActor
    func nativeToolbarKeepsLongRTLNameAtAccessibilityTextSize() async throws {
        try await verifyNativeToolbarKeepsSwitcherVisible(
            rootView: WalletHomeToolbarCollisionHarness(containerWidth: 320),
            size: CGSize(width: 320, height: 844), layout: .largeTextRTL
        )
    }

    @Test @MainActor
    func nativeToolbarKeepsLongNameSwitcherVisibleOnIPad() async throws {
        try await verifyNativeToolbarKeepsSwitcherVisible(
            rootView: WalletHomeToolbarCollisionHarness(containerWidth: 1_024),
            size: CGSize(width: 1_024, height: 1_366), layout: .pad
        )
    }

    @Test @MainActor
    func nativeToolbarKeepsAddAndSettingsControlsVisibleAtMinimumWidth() async throws {
        let host = try NativeListTestHost(size: CGSize(width: 320, height: 844)) {
            WalletHomeToolbarCollisionHarness(containerWidth: 320)
        }
        defer { host.close() }
        for identifier in ["wallet-home-add-wallet-regression", "wallet-home-settings-regression"] {
            try await SendEntryUIProbe.wait(in: host.rootView) {
                containsVisibleView(identifiedBy: identifier, in: host.rootView)
            }
        }
    }

    @Test @MainActor
    func nativeToolbarSeparatesAddConverterAndSettingsInLTR() async throws {
        let host = try NativeListTestHost {
            WalletHomeConverterToolbarHarness()
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            ["wallet-home-converter-regression", "wallet-home-add-regression",
             "wallet-home-settings-regression"].allSatisfy {
                containsVisibleView(identifiedBy: $0, in: host.rootView)
            }
        }
        let converterFrame = try #require(visibleFrame(
            identifiedBy: "wallet-home-converter-regression", in: host.rootView))
        let addFrame = try #require(visibleFrame(
            identifiedBy: "wallet-home-add-regression", in: host.rootView))
        let settingsFrame = try #require(visibleFrame(
            identifiedBy: "wallet-home-settings-regression", in: host.rootView))
        #expect(addFrame.maxX < converterFrame.minX)
        #expect(converterFrame.maxX < settingsFrame.minX)
    }

    @Test @MainActor
    func scrollStateUsesSeparateNameAndBalanceToolbarItems() async throws {
        let model = WalletHomeToolbarPresentationModel()
        let host = try NativeListTestHost {
            WalletHomeSeparateToolbarItemsHarness(model: model)
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            containsVisibleView(identifiedBy: WalletHomeWalletSwitcherToolbarID.name, in: host.rootView)
        }
        #expect(!containsVisibleView(
            identifiedBy: WalletHomeWalletSwitcherToolbarID.balance, in: host.rootView))
        model.showsBalance = true
        try await SendEntryUIProbe.wait(in: host.rootView) {
            !containsVisibleView(identifiedBy: WalletHomeWalletSwitcherToolbarID.name, in: host.rootView)
                && containsVisibleView(identifiedBy: WalletHomeWalletSwitcherToolbarID.balance, in: host.rootView)
        }
    }

    @MainActor
    private func verifyNativeToolbarKeepsSwitcherVisible<Content: View>(
        rootView: Content, size: CGSize, layout: NativeListTestLayout = .phone
    ) async throws {
        let host = try NativeListTestHost(layout: layout, size: size) { rootView }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            containsVisibleView(identifiedBy: "wallet-home-switcher-regression", in: host.rootView)
        }
    }

    @MainActor
    private func containsVisibleView(
        identifiedBy identifier: String,
        in view: UIView
    ) -> Bool {
        visibleFrame(identifiedBy: identifier, in: view) != nil
    }

    @MainActor
    private func visibleFrame(
        identifiedBy identifier: String, in view: UIView
    ) -> CGRect? {
        // SwiftUI may expose the toolbar identifier on an accessibility node
        // rather than a UIView. Its public screen frame is the visible contract.
        guard let control = SendEntryUIProbe.element(identifier, in: view),
              !control.accessibilityElementsHidden, view.window != nil else { return nil }
        if let nativeView = control as? UIView,
           nativeView.isHidden || nativeView.alpha <= 0.01 { return nil }
        let frame = control.accessibilityFrame
        guard !frame.isEmpty, !frame.isInfinite,
              frame.intersects(view.convert(view.bounds, to: nil)) else { return nil }
        return frame
    }

}

@MainActor
@Observable
private final class WalletHomeToolbarPresentationModel {
    var showsBalance = false
}

@MainActor
private struct WalletHomeSeparateToolbarItemsHarness: View {
    let model: WalletHomeToolbarPresentationModel

    var body: some View {
        NavigationStack {
            Color.clear
                .toolbar {
                    if model.showsBalance {
                        ToolbarItem(
                            id: WalletHomeWalletSwitcherToolbarID.balance,
                            placement: .topBarLeading
                        ) {
                            switcherButton {
                                WalletHomeSwitcherBalanceTitle(
                                    totalBalance: 12.34,
                                    currencyContext: WalletCurrencyContext(
                                        code: "USD",
                                        ratePerUSD: 1
                                    ),
                                    isBalanceHidden: false
                                )
                            }
                            .accessibilityIdentifier(
                                WalletHomeWalletSwitcherToolbarID.balance
                            )
                        }
                    } else {
                        ToolbarItem(
                            id: WalletHomeWalletSwitcherToolbarID.name,
                            placement: .topBarLeading
                        ) {
                            switcherButton {
                                Text(verbatim: "Wallet")
                                    .font(.headline)
                            }
                            .accessibilityIdentifier(
                                WalletHomeWalletSwitcherToolbarID.name
                            )
                        }
                    }
                }
        }
    }

    private func switcherButton<Title: View>(
        @ViewBuilder title: () -> Title
    ) -> some View {
        WalletHomeWalletSwitcherToolbarButton(
            color: .blue,
            maximumTitleWidth: 220,
            walletName: "Wallet",
            accessibilityValue: "",
            action: {},
            title: title
        )
    }
}

private struct WalletHomeToolbarCollisionHarness: View {
    let containerWidth: CGFloat

    var body: some View {
        NavigationStack {
            Color.clear
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: {}) {
                            WalletHomeWalletSwitcherToolbarLabel(
                                color: .red,
                                maximumTitleWidth:
                                    WalletHomeTopToolbarLayout
                                    .switcherTitleMaximumWidth(
                                        containerWidth: containerWidth
                                    )
                            ) {
                                Text(
                                    verbatim:
                                        "محفظة مستوردة njjjjsjsjsjsjsjjsjsjsjsjsjsjsjsk"
                                )
                                .font(.headline)
                            }
                        }
                        .accessibilityIdentifier(
                            "wallet-home-switcher-regression"
                        )
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: {}) {
                            Image(systemName: "plus")
                        }
                        .accessibilityIdentifier(
                            "wallet-home-add-wallet-regression"
                        )
                    }

                    WalletToolbarSpacer(.fixed, placement: .topBarTrailing)

                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: {}) {
                            Image(systemName: "ellipsis")
                        }
                        .accessibilityIdentifier(
                            "wallet-home-settings-regression"
                        )
                    }
                }
        }
    }
}

private struct WalletHomeConverterToolbarHarness: View {
    var body: some View {
        NavigationStack {
            Color.clear
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: {}) {
                            Image(systemName: "plus")
                        }
                        .accessibilityIdentifier(
                            "wallet-home-add-regression"
                        )
                    }

                    WalletToolbarSpacer(.fixed, placement: .topBarTrailing)

                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: {}) {
                            Image(systemName: "arrow.left.arrow.right")
                        }
                        .accessibilityIdentifier(
                            "wallet-home-converter-regression"
                        )
                    }

                    WalletToolbarSpacer(.fixed, placement: .topBarTrailing)

                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: {}) {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityIdentifier(
                            "wallet-home-settings-regression"
                        )
                    }
                }
        }
    }
}

@Suite("Native home Add menu", .serialized)
@MainActor
struct WalletHomeNativeAddMenuTests {
    @Test(arguments: NativeListTestLayout.allCases)
    func menuUsesNativeToolbarItemsWithoutCustomAppearance(layout: NativeListTestLayout) async throws {
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                Color.clear.toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        WalletHomeAddWalletMenu(onAddWallet: { _ in })
                    }
                    WalletToolbarSpacer(.fixed, placement: .topBarTrailing)
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {} label: { Image(systemName: "ellipsis") }
                    }
                }
            }
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            barItems(in: host).count >= 2
        }
        let menuItem = barItems(in: host).first { $0.menu != nil }
        let item = try #require(menuItem)
        #expect(item.customView == nil)
        #expect(item.style == .plain)
        #expect(item.tintColor == nil)
        #expect(item.image != nil)
        // Public bar-item properties establish that UIKit owns the appearance.
        // Private glass subview names and bounds are implementation details that
        // changed in iOS 27 and are not a stable compatibility contract.
    }

    private func barItems(in host: NativeListTestHost) -> [UIBarButtonItem] {
        guard let item = host.navigationController?.topViewController?.navigationItem else {
            return []
        }
        var seen = Set<ObjectIdentifier>()
        return (item.trailingItemGroups.flatMap(\.barButtonItems)
            + (item.rightBarButtonItems ?? []))
            .filter { seen.insert(ObjectIdentifier($0)).inserted }
            .filter { $0.customView != nil || $0.image != nil || $0.menu != nil }
    }
}

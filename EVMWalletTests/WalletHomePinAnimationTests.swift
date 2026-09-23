import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor
@Suite(.serialized)
struct WalletHomePinAnimationTests {
    @Test(arguments: NativeListTestLayout.allCases)
    func pinningKeepsRowContentInsideItsNativeCell(layout: NativeListTestLayout) async throws {
        let database = try WalletDatabase.temporary()
        let settings = WalletSettingsStore(database: database)
        let assets = (0..<4).map { index in
            WalletAsset(id: "eth:pin-test-\(index)", name: "Asset \(index)", symbol: "A\(index)",
                        logoSource: .unavailable, network: .ethereum,
                        balance: 1, fiatValue: Decimal(4 - index))
        }
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                WalletHomePortfolioView(
                    database: database,
                    snapshot: WalletHomeSnapshot(totalBalance: 10, assets: assets, transactions: []),
                    walletAddress: NativeListTestFixtures.address, capabilities: .fullWallet,
                    preparation: nil, onSend: {}, onSendAsset: { _ in }, onReceive: {},
                    onScan: {}, onPasteAddress: { _ in }, onScanAsset: { _ in },
                    onPasteAsset: { _, _ in }, onReceiveAsset: { _ in },
                    onManageAssets: { _ in }, onAssetVisibilityChanged: { _, _ in },
                    onAssetPinChanged: { _, _ in }, onShowAllActivity: { _ in },
                    onBalanceVisibilityChanged: { _ in }, onWalletActionsVisibilityChanged: { _ in },
                    onRefresh: {}, isAppSwitcherPrivacyActive: false
                )
            }
            .environment(settings)
        }
        defer { host.close() }
        let list = try await host.list()
        try await Task.sleep(for: .milliseconds(400))

        for (index, pinned) in [(1, true), (0, true), (2, true), (1, false), (0, false), (2, false)] {
            let json = try #require(WalletHomeAssetVisibility.updatedPreferencesJSON(
                settingPinned: pinned, for: assets[index], walletAddress: NativeListTestFixtures.address,
                preferencesJSON: settings.assetVisibilityPreferencesJSON))
            settings.setAssetVisibilityPreferencesJSON(json)
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(16))
                host.rootView.layoutIfNeeded()
                for cell in list.visibleCells {
                    // Native hosting tests do not always materialize SwiftUI's
                    // accessibility tree. Measure the real row background view.
                    for anchor in SendEntryUIProbe.views(WalletHomeSwipeAnchorView.self, in: cell) {
                        let frame = anchor.convert(anchor.bounds, to: cell)
                        #expect(frame.minY >= -1 && frame.maxY <= cell.bounds.height + 1,
                                "Row content \(frame) escaped native cell \(cell.bounds) during pin=\(pinned)")
                    }
                }
            }
            let resolution = WalletHomeAssetVisibility.resolution(
                walletAddress: NativeListTestFixtures.address,
                preferencesJSON: settings.assetVisibilityPreferencesJSON)
            let expectedPinned = assets.filter { resolution.isPinned($0) }
            #expect(list.numberOfSections == (expectedPinned.isEmpty ? 2 : 3))
            let expectedGroups = expectedPinned.isEmpty
                ? [assets] : [expectedPinned, assets.filter { !resolution.isPinned($0) }]
            for (groupIndex, group) in expectedGroups.enumerated() {
                #expect(list.numberOfItems(inSection: groupIndex + 1) == group.count)
                for row in group.indices {
                    let cell = try await host.cell(at: IndexPath(item: row, section: groupIndex + 1), in: list)
                    let anchor = try #require(SendEntryUIProbe.views(WalletHomeSwipeAnchorView.self, in: cell).first)
                    #expect(anchor.bounds.width > 0 && anchor.bounds.height > 0)
                }
            }
        }
    }

    @Test
    func aNonSwipeActionCommitsImmediately() {
        let completion = WalletHomeSwipeCompletion()
        var calls = 0
        completion.performAfterClosing { calls += 1 }
        #expect(calls == 1)
        completion.detach()
        #expect(calls == 1)
    }

    @Test
    func detachingASwipedRowPreservesOnePendingPin() async throws {
        let cell = SwipedCell()
        let anchor = UIView()
        cell.contentView.addSubview(anchor)
        let completion = WalletHomeSwipeCompletion()
        completion.anchor = anchor
        var calls = 0
        completion.performAfterClosing { calls += 1 }
        completion.performAfterClosing { calls += 10 }
        #expect(calls == 0)
        completion.detach()
        completion.detach()
        try await SendEntryUIProbe.wait(in: cell) { calls == 1 }
        #expect(calls == 1)
    }

    private final class SwipedCell: UICollectionViewCell {
        override var configurationState: UICellConfigurationState {
            var state = super.configurationState
            state.isSwiped = true
            return state
        }
    }
}

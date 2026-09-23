import SwiftUI
import Testing
import UIKit
import XCTest
@testable import Aperture

struct WalletActionPresentationLatencyFixTests {
    private let evmAddress =
        "0x1111111111111111111111111111111111111111"
    private let bitcoinAddress =
        "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"

    @Test
    func homeMoreActionsUseTextOnlyLabelsAndExplicitQRWording() {
        #expect(WalletHomeMoreAction.allCases == [.scan, .paste])
        #expect(
            WalletHomeMoreAction.scan.localizationKey
                == "wallet.home.action.scan_qr_code"
        )
        #expect(WalletHomeMoreAction.paste.localizationKey == "common.paste")

        let english = WalletAppLanguage.localizedBundle(for: "en")
        #expect(
            english.localizedString(
                forKey: WalletHomeMoreAction.scan.localizationKey,
                value: nil,
                table: nil
            ) == "Scan QR"
        )
        #expect(
            english.localizedString(
                forKey: WalletHomeMoreAction.paste.localizationKey,
                value: nil,
                table: nil
            ) == "Paste"
        )
    }

    @Test
    @MainActor
    func homeMoreNativeMenuContainsTextOnlyActions() async throws {
        let host = try NativeListTestHost {
            WalletHomeMoreActionMenu(
                onScan: {},
                onPasteAddress: { _ in }
            )
        }
        defer { host.close() }

        var menuButton: UIButton?
        for _ in 0..<100 {
            await Task.yield()
            host.rootView.setNeedsLayout()
            host.rootView.layoutIfNeeded()
            menuButton = nativeMenuButton(in: host.rootView)
            if menuButton?.menu != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let button = try #require(menuButton)
        let interaction = try #require(button.contextMenuInteraction)
        defer { interaction.dismissMenu() }
        button.performPrimaryAction()

        var actions: [UIAction] = []
        for _ in 0..<100 {
            await Task.yield()
            interaction.updateVisibleMenu { menu in
                actions = nativeActions(in: menu)
                return menu
            }
            if !actions.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(
            actions.map(\.title)
                == WalletHomeMoreAction.allCases.map(\.localizedTitle)
        )
        #expect(actions.allSatisfy { $0.image == nil })
    }

    @Test
    @MainActor
    func homeMoreControlKeepsACompactSquareFootprint() {
        let host = UIHostingController(
            rootView: WalletHomeMoreActionMenu(
                onScan: {},
                onPasteAddress: { _ in }
            )
        )
        let size = host.sizeThatFits(
            in: CGSize(width: 390, height: 844)
        )

        #expect(size.width >= 44)
        #expect(size.width <= 60)
        #expect(abs(size.width - size.height) <= 1)
    }

    @MainActor
    private func nativeMenuButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.menu != nil {
            return button
        }
        for subview in view.subviews {
            if let button = nativeMenuButton(in: subview) {
                return button
            }
        }
        return nil
    }

    @MainActor
    private func nativeActions(in menu: UIMenu) -> [UIAction] {
        menu.children.flatMap { element in
            if let action = element as? UIAction {
                return [action]
            }
            if let childMenu = element as? UIMenu {
                return nativeActions(in: childMenu)
            }
            return []
        }
    }

    @Test
    func receiveAddressIndexPreservesFirstValidAddressPerChain() {
        let index = ReceiveAddressIndex.make(
            from: [
                asset(
                    id: "eth:empty",
                    blockchain: .ethereum,
                    address: ""
                ),
                asset(
                    id: "eth:native",
                    blockchain: .ethereum,
                    address: evmAddress
                ),
                asset(
                    id: "eth:duplicate",
                    blockchain: .ethereum,
                    address:
                        "0x2222222222222222222222222222222222222222"
                ),
                asset(
                    id: "bitcoin:native",
                    blockchain: .bitcoin,
                    address: bitcoinAddress
                )
            ]
        )

        #expect(index[.ethereum] == evmAddress)
        #expect(index[.bitcoin] == bitcoinAddress)
    }

    @Test
    func assetListRenderingWindowExpandsWithoutLosingResults() {
        let totalCount = 2_874
        var visibleCount =
            AssetListRenderingWindow.initialCount(
                for: totalCount
            )

        #expect(visibleCount == 18)
        #expect(
            AssetListRenderingWindow.prefetchIndex(
                visibleCount: visibleCount,
                totalCount: totalCount
            ) == 12
        )

        while visibleCount < totalCount {
            let expanded = AssetListRenderingWindow.expandedCount(
                currentCount: visibleCount,
                totalCount: totalCount
            )
            #expect(expanded > visibleCount)
            #expect(expanded <= totalCount)
            visibleCount = expanded
        }

        #expect(visibleCount == totalCount)
        #expect(
            AssetListRenderingWindow.prefetchIndex(
                visibleCount: visibleCount,
                totalCount: totalCount
            ) == nil
        )
    }

    @Test
    func balanceRankedReplacementRecognizesOnlyStableRowMoves() {
        let current = ["trx", "usdt", "xlm"]
        let reordered = ["usdt", "trx", "xlm"]
        let expandedCurrent = (0..<40).map { "asset-\($0)" }
        let expandedReordered = [expandedCurrent[30]]
            + expandedCurrent.filter { $0 != expandedCurrent[30] }

        #expect(
            AssetListRenderingWindow.isStableReordering(
                from: current,
                to: reordered
            )
        )
        #expect(
            !AssetListRenderingWindow.isStableReordering(
                from: current,
                to: current
            )
        )
        #expect(
            !AssetListRenderingWindow.isStableReordering(
                from: current,
                to: ["usdt", "trx", "btc"]
            )
        )
        #expect(
            AssetListRenderingWindow.visibleCountAfterReplacing(
                currentCount: 36,
                currentIDs: expandedCurrent,
                updatedIDs: expandedReordered
            ) == 36
        )
    }

    @Test
    func catalogPromotionKeepsTheSameRenderedAssetIdentity() {
        let contract =
            "0x0000000000000000000000000000000000000042"
        let variant = ReceiveTokenVariant(
            networkID: "eth",
            contractAddress: contract,
            decimals: 6,
            networkRank: 1,
            logoURL: nil
        )
        let token = ReceiveToken(
            id: "test-usdt",
            name: "Tether USD",
            symbol: "USDT",
            rank: 1,
            isStablecoin: true,
            variants: [variant]
        )
        let catalog = AssetDiscoverySelection.catalog(
            ReceiveVariantSelection(token: token, variant: variant)
        )
        let holding = AssetDiscoverySelection.walletAsset(
            WalletAsset(
                id: variant.assetIdentity,
                name: token.name,
                symbol: token.symbol,
                logoSource: .unavailable,
                network: .ethereum,
                balance: 100,
                fiatValue: 100
            )
        )

        #expect(catalog.canonicalAssetIdentity == holding.canonicalAssetIdentity)
        #expect(catalog.id == holding.id)
    }

    @Test
    func directAccountResolutionSkipsValidatedCachedAddresses() {
        let aptosAddress =
            "0xe9c4d0b6fe32a5cc8ebd1e9ad5b54a0276a57f2d081dcb5e30342319963626c3"
        let cachedAptos = asset(
            id: AptosConstants.nativeAssetID,
            blockchain: .aptos,
            address: aptosAddress
        )
        let cachedPlan = ReceiveDirectAccountResolutionPlan(
            capabilities: WalletCapabilities(scope: .privateKey(.aptos)),
            availableAssets: [cachedAptos]
        )
        let missingPlan = ReceiveDirectAccountResolutionPlan(
            capabilities: WalletCapabilities(scope: .privateKey(.aptos)),
            availableAssets: []
        )

        #expect(!cachedPlan.aptos)
        #expect(missingPlan.aptos)
    }

    private func asset(
        id: String,
        blockchain: WalletBlockchain,
        address: String
    ) -> WalletAsset {
        WalletAsset(
            id: id,
            name: id,
            symbol: id,
            logoSource: .nativeCoin(blockchain: blockchain),
            network: blockchain,
            balance: 0,
            fiatValue: 0,
            receiveAddress: address
        )
    }
}

@MainActor
final class WalletHomeScrollVisibilityIntegrationTests: XCTestCase {
    func testListScrollReportsThresholdEdgesAfterRowsRecycle() {
        let hiddenVisibility = expectation(
            description: "Both top rows report hidden"
        )
        let restoredVisibility = expectation(
            description: "Both top rows report visible again"
        )
        var hiddenReportCount = 0
        var restoredReportCount = 0
        var didReportHidden = false
        var thresholds = WalletHomeScrollVisibilityThresholds()
        thresholds.recordBalanceHeight(120)
        thresholds.recordActionsHeight(120)
        let rootView = List {
            Color.clear
                .frame(height: 120)

            Color.clear
                .frame(height: 120)

            ForEach(0..<60, id: \.self) { index in
                Text(String(index))
                    .frame(height: 52)
            }
        }
        .walletHomeScrollVisibility(thresholds: thresholds) { visibility in
            if !visibility.balance, !visibility.actions, !didReportHidden {
                didReportHidden = true
                hiddenReportCount += 1
                hiddenVisibility.fulfill()
            } else if visibility == .allVisible, didReportHidden {
                restoredReportCount += 1
                restoredVisibility.fulfill()
            }
        }
        .listStyle(.insetGrouped)
        let host = UIHostingController(rootView: rootView)
        let window = UIWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        guard let scrollView = firstScrollView(in: host.view) else {
            XCTFail("The hosted List did not create a scroll view.")
            window.isHidden = true
            return
        }
        let maximumOffset = max(
            0,
            scrollView.contentSize.height - scrollView.bounds.height
        )
        XCTAssertGreaterThan(maximumOffset, 200)
        for offset in [300.0, 450.0, 600.0] {
            scrollView.setContentOffset(
                CGPoint(x: 0, y: min(offset, maximumOffset)),
                animated: false
            )
            scrollView.layoutIfNeeded()
            host.view.layoutIfNeeded()
        }

        wait(for: [hiddenVisibility], timeout: 1)
        XCTAssertEqual(hiddenReportCount, 1)

        scrollView.setContentOffset(
            CGPoint(x: 0, y: -scrollView.adjustedContentInset.top),
            animated: false
        )
        scrollView.layoutIfNeeded()
        host.view.layoutIfNeeded()

        wait(for: [restoredVisibility], timeout: 1)
        XCTAssertEqual(restoredReportCount, 1)
        window.isHidden = true
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let scrollView = firstScrollView(in: subview) {
                return scrollView
            }
        }
        return nil
    }
}

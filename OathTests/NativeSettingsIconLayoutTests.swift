import SwiftUI
import Testing
import UIKit
@testable import Aperture

extension NativeListInteractionTests {
    @Test
    func appInformationRowsShareOneNativeSection() async throws {
        let settings = WalletSettingsStore(
            database: try WalletDatabase.temporary()
        )
        let host = try NativeListTestHost {
            NavigationStack {
                WalletSettingsView()
                    .navigationDestination(
                        for: WalletSettingsSearchRoute.self
                    ) { _ in
                        Text("common.done")
                    }
            }
            .environment(settings)
        }
        defer { host.close() }

        let list = try await host.list { list in
            (0..<list.numberOfSections).map(
                list.numberOfItems(inSection:)
            ) == [1, 6, 1, 2, 1]
        }

        #expect(list.numberOfSections == 5)
        #expect(list.numberOfItems(inSection: 3) == 2)
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func settingsIconRowsKeepNativeLayoutAndControls(layout: NativeListTestLayout) async throws {
        let settings = WalletSettingsStore(database: try WalletDatabase.temporary())
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                WalletSettingsView()
                    .navigationDestination(for: WalletSettingsSearchRoute.self) { _ in
                        Text("common.done")
                    }
            }
            .environment(settings)
        }
        defer { host.close() }
        let list = try await host.list { $0.numberOfSections == 5 }
        #expect(
            (0..<list.numberOfSections).map(
                list.numberOfItems(inSection:)
            ) == [1, 6, 1, 2, 1]
        )
        let bundle = WalletAppLanguage.localizedBundle(
            for: layout.direction == .rightToLeft ? "ar" : "en"
        )
        let navigationRows: [(IndexPath, String)] = [
            (IndexPath(item: 0, section: 0), "settings.wallets.title"),
            (IndexPath(item: 1, section: 1), "settings.security.title"),
            (IndexPath(item: 2, section: 1), "settings.appearance.title"),
            (IndexPath(item: 3, section: 1), "settings.language.title"),
            (IndexPath(item: 4, section: 1), "settings.currency.title"),
            (IndexPath(item: 5, section: 1), "settings.notifications.title"),
            (IndexPath(item: 0, section: 2), "settings.section.tools"),
            (IndexPath(item: 0, section: 3), "settings.about.title")
        ]
        for (path, titleKey) in navigationRows {
            let cell = try await host.cell(at: path, in: list)
            let title = bundle.localizedString(forKey: titleKey, value: nil, table: nil)
            // Native LabeledContent combines title and value for VoiceOver in
            // locale-dependent reading order, including bidirectional markers.
            let row = try #require(host.accessibilityAction(in: cell) {
                $0.contains(title)
            }, "The native navigation row must announce \(titleKey)")
            #expect(!row.accessibilityTraits.contains(.notEnabled))
            #expect(list.delegate?.collectionView?(list, shouldHighlightItemAt: path) == true)
            if titleKey == "settings.security.title" {
                #expect(list.delegate?.collectionView?(
                    list,
                    canPerformPrimaryActionForItemAt: path
                ) == true)
            } else {
                #expect(list.delegate?.collectionView?(
                    list,
                    shouldSelectItemAt: path
                ) == true)
            }
            #expect(cell.bounds.width > 0 && cell.bounds.height >= SettingsIconMetrics.size)
            #expect(cell.bounds.width <= list.bounds.width)
        }

        let ratingPath = IndexPath(item: 1, section: 3)
        let ratingCell = try await host.cell(at: ratingPath, in: list)
        let ratingTitle = bundle.localizedString(
            forKey: "settings.app_store_rating.title",
            value: nil,
            table: nil
        )
        let ratingAction = try #require(
            host.accessibilityAction(in: ratingCell) {
                $0.contains(ratingTitle)
            }
        )
        #expect(!ratingAction.accessibilityTraits.contains(.notEnabled))
        #expect(
            list.delegate?.collectionView?(
                list,
                canPerformPrimaryActionForItemAt: ratingPath
            ) == true
        )
        #expect(ratingCell.bounds.height >= SettingsIconMetrics.size)

        let toggleCell = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
        let toggle = try #require(settingsNativeSwitch(in: toggleCell))
        let originalValue = settings.hapticFeedbackEnabled
        defer { settings.setHapticFeedbackEnabled(originalValue) }
        toggle.setOn(!originalValue, animated: false)
        toggle.sendActions(for: .valueChanged)
        await Task.yield()
        #expect(settings.hapticFeedbackEnabled == !originalValue)
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func toolsCatalogUsesNativeIconRows(
        layout: NativeListTestLayout
    ) async throws {
        let database = try WalletDatabase.temporary()
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                ToolsSettingsView(database: database)
                    .navigationDestination(
                        for: WalletSettingsSearchRoute.self
                    ) { _ in
                        Text("common.done")
                    }
            }
        }
        defer { host.close() }

        let list = try await host.list {
            $0.numberOfSections == 1
                && $0.numberOfItems(inSection: 0) == 4
        }
        let bundle = WalletAppLanguage.localizedBundle(
            for: layout.direction == .rightToLeft ? "ar" : "en"
        )
        let keys = [
            "settings.converter.title",
            "network_fees.title",
            "settings.tools.broadcast_bitcoin.title",
            "settings.tools.mnemonic_last_word.title"
        ]
        for (item, key) in keys.enumerated() {
            let path = IndexPath(item: item, section: 0)
            let cell = try await host.cell(at: path, in: list)
            let title = bundle.localizedString(
                forKey: key,
                value: nil,
                table: nil
            )
            let row = try #require(host.accessibilityAction(in: cell) {
                $0.contains(title)
            })

            #expect(!row.accessibilityTraits.contains(.notEnabled))
            #expect(
                list.delegate?.collectionView?(
                    list,
                    shouldSelectItemAt: path
                ) == true
            )
            #expect(cell.bounds.height >= SettingsIconMetrics.size)
        }
    }
}

@MainActor
private func settingsNativeSwitch(in view: UIView) -> UISwitch? {
    if let toggle = view as? UISwitch { return toggle }
    for child in view.subviews {
        if let toggle = settingsNativeSwitch(in: child) { return toggle }
    }
    return nil
}

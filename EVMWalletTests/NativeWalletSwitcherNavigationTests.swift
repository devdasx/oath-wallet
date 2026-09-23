import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor
@Suite(.serialized)
struct NativeWalletSwitcherNavigationTests {
    @Test(arguments: NativeListTestLayout.allCases)
    func allAddActionsPushInsideTheOriginalSheetAndBackReturnsToWallets(
        layout: NativeListTestLayout
    ) async throws {
        let test = try NativeWalletSwitcherTestHost(layout: layout)
        defer { test.close() }
        let presentation = try await test.presentation()
        let navigation = try #require(test.navigation(in: presentation))

        for action in HomeWalletAddAction.allCases {
            try await test.selectAction(action, in: navigation)
            let titleKey: String
            switch action {
            case .create: titleKey = "wallet.creation.commit.navigation"
            case .importWallet: titleKey = "import.navigation.title"
            case .restoreICloud: titleKey = "import.icloud.navigation.title"
            }
            try await test.settle {
                navigation.viewControllers.count == 2
                    && navigation.transitionCoordinator == nil
                    && navigation.topViewController?.navigationItem.title == test.title(titleKey)
            }
            #expect(test.state.path == [.setup(.entry(for: action))])
            test.assertSameSheet(presentation, navigation: navigation)

            try await test.pop(navigation, toDepth: 1)
            #expect(navigation.topViewController?.navigationItem.title == test.title("settings.wallets.title"))
            test.assertSameSheet(presentation, navigation: navigation)
        }
        #expect(test.state.completedAddresses.isEmpty)
        #expect(try await test.database.managedWalletCount() == 0)
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func importMethodsAndBackupDetailsStayInTheSameNavigationStack(
        layout: NativeListTestLayout
    ) async throws {
        let test = try NativeWalletSwitcherTestHost(layout: layout)
        defer { test.close() }
        let presentation = try await test.presentation()
        let navigation = try #require(test.navigation(in: presentation))
        try await test.selectAction(.importWallet, in: navigation)
        try await test.settle {
            navigation.viewControllers.count == 2 && navigation.transitionCoordinator == nil
        }

        let methods: [WalletSwitcherSetupRoute] = [
            .importRecoveryPhrase,
            .privateKeyNetworks,
            .physicalEntropy,
            .restoreICloud
        ]
        for (index, route) in methods.enumerated() {
            let top = try #require(navigation.topViewController)
            let list = try await test.list(in: top, rows: methods.count)
            let section = try #require((0..<list.numberOfSections).first {
                list.numberOfItems(inSection: $0) == methods.count
            })
            try await test.host.selectRow(IndexPath(item: index, section: section), in: list)
            try await test.settle {
                navigation.viewControllers.count == 3 && navigation.transitionCoordinator == nil
            }
            #expect(test.state.path.last == .setup(route))
            test.assertSameSheet(presentation, navigation: navigation)

            if route == .restoreICloud {
                let restore = try #require(navigation.topViewController)
                let backups = try await test.list(in: restore, rows: 1)
                // A selection-backed List dispatches NavigationLink through
                // its primary action outside edit mode, not didSelect.
                try await test.host.selectRow(IndexPath(item: 0, section: 0), in: backups)
                try await test.settle {
                    navigation.viewControllers.count == 4 && navigation.transitionCoordinator == nil
                }
                #expect(test.state.path.last == .setup(.restoreBackup(WalletSwitcherSetupTestFixtures.backup)))
                test.assertSameSheet(presentation, navigation: navigation)
                try await test.pop(navigation, toDepth: 3)
            }
            try await test.pop(navigation, toDepth: 2)
            test.assertSameSheet(presentation, navigation: navigation)
        }
        #expect(try await test.database.managedWalletCount() == 0)
    }

    @Test
    func createActionPushesRecoveryWithoutAMethodScreen() async throws {
        let test = try NativeWalletSwitcherTestHost()
        defer { test.close() }
        let presentation = try await test.presentation()
        let navigation = try #require(test.navigation(in: presentation))
        try await test.selectAction(.create, in: navigation)
        try await test.settle {
            navigation.viewControllers.count == 2 && navigation.transitionCoordinator == nil
        }
        let recovery = try #require(navigation.topViewController)
        _ = try await test.list(in: recovery, rows: 7) // 6 word pairs and Copy.
        test.assertSameSheet(presentation, navigation: navigation)
        #expect(test.state.path == [.setup(.recovery)])
        #expect(test.state.completedAddresses.isEmpty)
        #expect(try await test.database.managedWalletCount() == 0)
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func physicalEntropyStartsFromImportMethods(
        layout: NativeListTestLayout
    ) async throws {
        let test = try NativeWalletSwitcherTestHost(layout: layout)
        defer { test.close() }
        let presentation = try await test.presentation()
        let navigation = try #require(test.navigation(in: presentation))
        try await test.selectAction(.importWallet, in: navigation)
        let list = try await test.list(
            in: try #require(navigation.topViewController),
            rows: ImportWalletOption.allCases.count - 1
        )
        let section = try #require((0..<list.numberOfSections).first {
            list.numberOfItems(inSection: $0)
                == ImportWalletOption.allCases.count - 1
        })
        let displayedOptions = ImportWalletOption.allCases.filter {
            $0 != .transferFromIPhone
        }
        let row = try #require(
            displayedOptions.firstIndex(of: .physicalEntropy)
        )
        try await test.host.selectRow(
            IndexPath(item: row, section: section),
            in: list
        )
        try await test.settle {
            test.state.path.last == .setup(.physicalEntropy)
                && navigation.viewControllers.count == 3
                && navigation.topViewController?.navigationItem.title
                    == test.title("wallet.creation.entropy.navigation")
        }
        test.assertSameSheet(presentation, navigation: navigation)
    }
}

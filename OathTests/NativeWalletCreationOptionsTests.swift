import SwiftUI
import Testing
import UIKit
@testable import Aperture

extension NativeListInteractionTests {
    @Test(arguments: [false, true])
    func quickWalletRecoveryMenuContainsOnlyPassphraseManagement(
        hasPassphrase: Bool
    ) async throws {
        let host = try NativeListTestHost {
            NavigationStack {
                SettingsWalletCreationRecoveryScreen(
                    // Public BIP39 fixture; never a user's recovery phrase.
                    words: Array(repeating: "abandon", count: 11) + ["about"],
                    hasPassphrase: hasPassphrase,
                    isSaving: false,
                    onManagePassphrase: {},
                    onContinue: {}
                )
            }
        }
        defer { host.close() }
        _ = try await host.list()
        let navigation = try #require(host.navigationController)
        try await settleWalletCreationView(host.rootView) {
            self.creationMenuButton(in: navigation.navigationBar) != nil
        }
        let button = try #require(creationMenuButton(in: navigation.navigationBar))
        let interaction = try #require(button.contextMenuInteraction)
        defer { interaction.dismissMenu() }
        button.performPrimaryAction()

        // SwiftUI resolves its deferred actions only when the native menu opens.
        var titles: [String] = []
        try await settleWalletCreationView(host.rootView) {
            interaction.updateVisibleMenu { menu in
                titles = self.creationMenuActionTitles(menu)
                return menu
            }
            return !titles.isEmpty
        }
        let english = WalletAppLanguage.localizedBundle(for: "en")
        let expectedKey = hasPassphrase
            ? "wallet.creation.passphrase.edit"
            : "wallet.creation.passphrase.add"

        #expect(titles == [english.localizedString(forKey: expectedKey, value: nil, table: nil)])
        #expect(!titles.contains(english.localizedString(
            forKey: "wallet.creation.entropy.menu", value: nil, table: nil
        )))
        #expect(english.localizedString(
            forKey: "wallet.creation.passphrase.add", value: nil, table: nil
        ) == "Add a BIP-39 Passphrase")
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func importMethodsPushPhysicalEntropyScreen(
        layout: NativeListTestLayout
    ) async throws {
        let database = try WalletDatabase.temporary()
        let host = try NativeListTestHost(layout: layout) {
            OnboardingView(
                database: database,
                startAction: .importWallet
            )
        }
        defer { host.close() }
        let list = try await host.list { list in
            (0..<list.numberOfSections).contains { section in
                list.numberOfItems(inSection: section)
                    == ImportWalletOption.allCases.count
            }
        }
        let navigation = try #require(host.navigationController)
        #expect(navigation.viewControllers.count == 1)
        let section = try #require((0..<list.numberOfSections).first {
            list.numberOfItems(inSection: $0)
                == ImportWalletOption.allCases.count
        })
        let row = try #require(
            ImportWalletOption.allCases.firstIndex(of: .physicalEntropy)
        )
        let bundle = WalletAppLanguage.localizedBundle(
            for: layout.direction == .rightToLeft ? "ar" : "en"
        )
        let inputTitle = bundle.localizedString(
            forKey: "wallet.creation.entropy.navigation", value: nil, table: nil
        )
        try await host.selectRow(IndexPath(item: row, section: section), in: list)
        try await settleWalletCreationView(host.rootView) {
            navigation.viewControllers.count == 2
                && navigation.transitionCoordinator == nil
                && navigation.topViewController?.navigationItem.title == inputTitle
        }
        #expect(navigation.presentedViewController == nil)

        navigation.popViewController(animated: false)
        let importTitle = bundle.localizedString(
            forKey: "import.navigation.title",
            value: nil,
            table: nil
        )
        try await settleWalletCreationView(host.rootView) {
            navigation.viewControllers.count == 1
                && navigation.topViewController?.navigationItem.title == importTitle
        }
    }

    @Test(arguments: [
        "https://aperturex.io/app/create-wallet/entropy",
        "aperturewallet://create-wallet/entropy"
    ])
    func entropyLinksOpenPhysicalEntropyCreationDirectly(
        urlString: String
    ) async throws {
        let database = try WalletDatabase.temporary()
        let coordinator = WalletAppDeepLinkCoordinator()
        let settings = WalletSettingsStore(database: database)
        let completed = ListActionRecorder<String>()
        let host = try NativeListTestHost {
            Text("common.done")
                .walletEntropyEventDeepLink(database: database) {
                    completed.actions.append($0)
                }
                .environment(coordinator)
                .environment(settings)
        }
        defer { host.close() }
        let root = try #require(host.rootView.window?.rootViewController)
        #expect(coordinator.handle(try #require(URL(string: urlString))))
        try await settleWalletCreationView(host.rootView) {
            guard let presented = root.presentedViewController else { return false }
            return self.findCreationNavigation(in: presented)?
                .topViewController?.navigationItem.title
                == WalletLocalization.string(
                    "wallet.creation.entropy.navigation"
                )
        }

        let presented = try #require(root.presentedViewController)
        let navigation = try #require(findCreationNavigation(in: presented))
        #expect(navigation.viewControllers.count == 2)
        #expect(navigation.presentedViewController == nil)
        #expect(coordinator.pendingRequest == nil)
        #expect(completed.actions.isEmpty)
        #expect(try await database.managedWalletCount() == 0)
        presented.dismiss(animated: false)
    }

    private func creationMenuButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.menu != nil { return button }
        for child in view.subviews {
            if let button = creationMenuButton(in: child) { return button }
        }
        return nil
    }

    private func creationMenuActionTitles(_ menu: UIMenu) -> [String] {
        menu.children.flatMap { element in
            if let child = element as? UIMenu { return creationMenuActionTitles(child) }
            if let action = element as? UIAction { return [action.title] }
            return []
        }
    }

    private func findCreationNavigation(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        for child in controller.children {
            if let navigation = findCreationNavigation(in: child) { return navigation }
        }
        return nil
    }

    private func settleWalletCreationView(
        _ view: UIView,
        until isReady: () -> Bool
    ) async throws {
        for _ in 0..<150 {
            await Task.yield()
            view.layoutIfNeeded()
            if isReady() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(isReady(), "Native wallet creation navigation did not settle")
    }
}

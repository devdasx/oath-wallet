import SwiftUI
import Testing
import UIKit
@testable import Aperture

/// Uses native controls and dummy passphrases only; no wallet is imported.
@MainActor
@Suite(.serialized)
struct NativeRecoveryOptionsNavigationTests {
    @Test(arguments: ImportDraftTestFlow.allCases, [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func passphraseRequiresExplicitSaveAndBackDiscardsEdits(
        flow: ImportDraftTestFlow, layout: NativeListTestLayout
    ) async throws {
        let saved = ListActionRecorder<String>()
        let host = try credentialHost(flow: flow, layout: layout, saved: saved)
        defer { host.close() }
        let navigation = try await navigation(host)

        try await openPassphrase(navigation)
        let saveTitle = title("common.save", layout: layout)
        #expect(try saveControl(navigation).accessibilityLabel == saveTitle)
        #expect(try saveItem(navigation).title?.isEmpty != false)
        try await expectSaveHasNoEffect(navigation, saved: saved)
        try await replaceField(0, with: "discard this edit", host: host, navigation: navigation)
        try await expectSaveHasNoEffect(navigation, saved: saved) // Confirmation does not match.
        try await back(navigation)
        #expect(saved.actions.isEmpty)

        try await openPassphrase(navigation)
        #expect(try await field(0, host: host, navigation: navigation).text == "original test passphrase")
        #expect(try await field(1, host: host, navigation: navigation).text == "original test passphrase")

        let tooLong = String(repeating: "x", count: WalletRecoveryCredential.maximumPassphraseUTF8Count + 1)
        try await replaceField(0, with: tooLong, host: host, navigation: navigation)
        try await replaceField(1, with: tooLong, host: host, navigation: navigation)
        try await expectSaveHasNoEffect(navigation, saved: saved)

        let edited = "caf\u{00e9} test passphrase"
        try await replaceField(0, with: edited, host: host, navigation: navigation)
        try await expectSaveHasNoEffect(navigation, saved: saved)
        try await replaceField(1, with: edited, host: host, navigation: navigation)
        try await SendEntryUIProbe.wait(in: navigation.view) {
            saveDisabledState(navigation) == false
        }
        try activateSave(navigation)
        try await settle(navigation, depth: 1)
        let normalized = edited.decomposedStringWithCompatibilityMapping
        #expect(saved.actions.map { Array($0.utf8) } == [Array(normalized.utf8)])

        // Removing an existing passphrase is a real change and must be savable.
        try await openPassphrase(navigation)
        #expect(try await field(0, host: host, navigation: navigation).text == normalized)
        try await expectSaveHasNoEffect(navigation, saved: saved)
        try await replaceField(0, with: "", host: host, navigation: navigation)
        try await replaceField(1, with: "", host: host, navigation: navigation)
        try await SendEntryUIProbe.wait(in: navigation.view) {
            saveDisabledState(navigation) == false
        }
        try activateSave(navigation)
        try await settle(navigation, depth: 1)
        #expect(saved.actions == [normalized, ""])
        #expect(navigation.presentedViewController == nil)
    }

    @Test(arguments: ImportDraftTestFlow.allCases, [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func wordListPushesAndReturnsWithoutASaveAction(
        flow: ImportDraftTestFlow, layout: NativeListTestLayout
    ) async throws {
        let saved = ListActionRecorder<String>()
        let host = try credentialHost(flow: flow, layout: layout, saved: saved)
        defer { host.close() }
        let navigation = try await navigation(host)
        try await openOption(1, navigation: navigation)
        try await settle(navigation, depth: 2)
        let screen = try #require(navigation.topViewController)
        #expect(screen.navigationItem.title == title("import.recovery.word_list.title", layout: layout))
        #expect(!screen.navigationItem.hidesBackButton)
        #expect(!trailingItems(navigation).contains {
            $0.title == title("common.save", layout: layout)
                || $0.accessibilityIdentifier == "importRecoveryPassphraseSave"
        })
        #expect(navigation.presentedViewController == nil)
        try await SendEntryUIProbe.wait(in: navigation.view) {
            screen.navigationItem.searchController != nil
        }
        let search = try #require(screen.navigationItem.searchController)
        search.isActive = true
        try await SendEntryUIProbe.wait(in: navigation.view) {
            search.isActive && search.viewIfLoaded?.window != nil
                && !search.isBeingPresented && search.transitionCoordinator == nil
        }
        #expect(search.searchBar.searchTextField.becomeFirstResponder())
        search.searchBar.searchTextField.insertText("abandon")
        search.searchResultsUpdater?.updateSearchResults(for: search)
        try await SendEntryUIProbe.wait(in: screen.view) {
            SendEntryUIProbe.views(UICollectionView.self, in: screen.view).contains {
                $0.numberOfSections == 2 && $0.numberOfItems(inSection: 1) == 1
            }
        }
        // Drive the native Cancel delegate so SwiftUI also receives the
        // search-state change, then finish dismissal before navigating Back.
        let delegate = try #require(search.searchBar.delegate)
        #expect(delegate.responds(to: #selector(UISearchBarDelegate.searchBarCancelButtonClicked(_:))))
        delegate.searchBarCancelButtonClicked?(search.searchBar)
        try await SendEntryUIProbe.wait(in: navigation.view) {
            !search.isActive && !search.isBeingPresented && !search.isBeingDismissed
                && search.transitionCoordinator == nil
                && screen.presentedViewController == nil
                && navigation.transitionCoordinator == nil
        }
        try await back(navigation)
        #expect(saved.actions.isEmpty)
        #expect(navigation.topViewController?.navigationItem.title
            == title("import.recovery.title", layout: layout))
    }

    private func credentialHost(
        flow: ImportDraftTestFlow, layout: NativeListTestLayout, saved: ListActionRecorder<String>
    ) throws -> NativeListTestHost {
        try NativeListTestHost(layout: layout) {
            NavigationStack {
                switch flow {
                case .onboarding:
                    ImportWalletCredentialView(
                        credential: .recoveryPhrase, initialPassphrase: "original test passphrase",
                        onPassphraseChange: { saved.actions.append($0) }, onImport: { _ in
                            Issue.record("Navigation tests must not import wallets")
                        }
                    )
                case .walletSwitcher:
                    WalletSwitcherRecoveryImportScreen(
                        credential: .recoveryPhrase, initialPassphrase: "original test passphrase",
                        onPassphraseChange: { saved.actions.append($0) }, onImport: { _ in
                            Issue.record("Navigation tests must not import wallets")
                        }
                    )
                }
            }
        }
    }

    private func navigation(_ host: NativeListTestHost) async throws -> UINavigationController {
        try await SendEntryUIProbe.wait(in: host.rootView) {
            host.navigationController?.viewControllers.count == 1
        }
        return try #require(host.navigationController)
    }

    private func openOption(_ index: Int, navigation: UINavigationController) async throws {
        navigation.view.endEditing(true)
        try await SendEntryUIProbe.wait(in: navigation.view) {
            SendEntryUIProbe.views(UIButton.self, in: navigation.navigationBar).contains { $0.menu != nil }
        }
        let button = try #require(SendEntryUIProbe.views(UIButton.self, in: navigation.navigationBar)
            .first { $0.menu != nil })
        let interaction = try #require(button.contextMenuInteraction)
        defer { interaction.dismissMenu() }
        button.performPrimaryAction()
        var actions: [UIAction] = []
        try await SendEntryUIProbe.wait(in: navigation.view) {
            interaction.updateVisibleMenu { menu in
                actions = menuActions(menu)
                return menu
            }
            return actions.count == 2
        }
        let action = actions[index]
        interaction.dismissMenu()
        button.sendAction(action)
    }

    private func menuActions(_ menu: UIMenu) -> [UIAction] {
        menu.children.flatMap { element in
            if let action = element as? UIAction { return [action] }
            if let menu = element as? UIMenu { return menuActions(menu) }
            return []
        }
    }

    private func field(
        _ index: Int, host: NativeListTestHost, navigation: UINavigationController
    ) async throws -> UITextField {
        let view = try #require(navigation.topViewController?.view)
        try await SendEntryUIProbe.wait(in: view) {
            !SendEntryUIProbe.views(UICollectionView.self, in: view).isEmpty
        }
        let list = try #require(SendEntryUIProbe.views(UICollectionView.self, in: view).first)
        let cell = try await host.cell(at: IndexPath(item: index, section: 0), in: list)
        return try #require(SendEntryUIProbe.views(UITextField.self, in: cell).first)
    }

    private func replaceField(
        _ index: Int, with value: String, host: NativeListTestHost, navigation: UINavigationController
    ) async throws {
        let input = try await field(index, host: host, navigation: navigation)
        #expect(input.becomeFirstResponder())
        input.selectedTextRange = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument)
        if value.isEmpty { input.deleteBackward() } else { input.insertText(value) }
        try await SendEntryUIProbe.wait(in: navigation.view) { input.text == value }
        navigation.view.endEditing(true)
        await Task.yield()
    }

    private func trailingItems(_ navigation: UINavigationController) -> [UIBarButtonItem] {
        guard let item = navigation.topViewController?.navigationItem else { return [] }
        var seen: Set<ObjectIdentifier> = []
        return (item.trailingItemGroups.flatMap(\.barButtonItems) + (item.rightBarButtonItems ?? []))
            .filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    private func saveItem(_ navigation: UINavigationController) throws -> UIBarButtonItem {
        try #require(trailingItems(navigation).first)
    }

    private func saveControl(_ navigation: UINavigationController) throws -> NSObject {
        try #require(SendEntryUIProbe.element("importRecoveryPassphraseSave", in: navigation.navigationBar))
    }

    private func saveIsDisabled(_ navigation: UINavigationController) throws -> Bool {
        try #require(saveDisabledState(navigation))
    }

    private func expectSaveHasNoEffect(
        _ navigation: UINavigationController, saved: ListActionRecorder<String>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        #expect(try saveIsDisabled(navigation), sourceLocation: sourceLocation)
        let previousActions = saved.actions
        let screen = try #require(navigation.topViewController)
        let item = try saveItem(navigation)
        // Exercise the action boundary too: even direct dispatch must not
        // commit an unchanged, mismatched, or oversized passphrase.
        if let action = item.action {
            _ = UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil)
        }
        await Task.yield()
        navigation.view.layoutIfNeeded()
        #expect(saved.actions == previousActions, sourceLocation: sourceLocation)
        #expect(navigation.topViewController === screen, sourceLocation: sourceLocation)
        #expect(navigation.viewControllers.count == 2, sourceLocation: sourceLocation)
    }

    private func saveDisabledState(_ navigation: UINavigationController) -> Bool? {
        guard let item = trailingItems(navigation).first,
              let control = SendEntryUIProbe.element(
                "importRecoveryPassphraseSave", in: navigation.navigationBar) else { return nil }
        // iOS 18 removes the Save selector when disabled rather than setting
        // the UIKit wrapper's flags. A primary UIAction takes precedence over
        // target/action, so inspect it before treating a missing selector as disabled.
        let hasAction = item.primaryAction.map { !$0.attributes.contains(.disabled) }
            ?? (item.action != nil)
        return !hasAction || !item.isEnabled || (control as? UIControl)?.isEnabled == false
            || control.accessibilityTraits.contains(.notEnabled)
    }

    private func openPassphrase(_ navigation: UINavigationController) async throws {
        try await openOption(0, navigation: navigation)
        try await settle(navigation, depth: 2)
        // Navigation depth can settle before SwiftUI installs the toolbar item.
        try await SendEntryUIProbe.wait(in: navigation.view) {
            saveDisabledState(navigation) != nil
        }
    }

    private func activateSave(_ navigation: UINavigationController) throws {
        #expect(try saveIsDisabled(navigation) == false)
        let item = try saveItem(navigation)
        let action = try #require(item.action)
        #expect(UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil))
    }

    private func back(_ navigation: UINavigationController) async throws {
        #expect(navigation.topViewController?.navigationItem.hidesBackButton == false)
        navigation.view.endEditing(true)
        #expect(navigation.popViewController(animated: true) != nil)
        try await settle(navigation, depth: 1)
        #expect(navigation.presentedViewController == nil)
    }

    private func settle(
        _ navigation: UINavigationController, depth: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await SendEntryUIProbe.wait(in: navigation.view, sourceLocation: sourceLocation) {
            navigation.viewControllers.count == depth && navigation.transitionCoordinator == nil
        }
    }

    private func title(_ key: String, layout: NativeListTestLayout) -> String {
        WalletAppLanguage.localizedBundle(for: layout.direction == .rightToLeft ? "ar" : "en")
            .localizedString(forKey: key, value: nil, table: nil)
    }
}

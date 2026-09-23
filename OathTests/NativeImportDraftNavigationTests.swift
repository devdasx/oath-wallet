import Observation
import SwiftUI
import Testing
import UIKit
@testable import Aperture

enum ImportDraftTestFlow: CaseIterable {
    case onboarding, walletSwitcher
}

/// Real navigation and input controls, with invalid fixture text only.
@MainActor
@Suite(.serialized)
struct NativeImportDraftNavigationTests {
    @Test(arguments: ImportDraftTestFlow.allCases, [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func backOutDiscardsEachCredentialAndEndingTheFlowClearsIt(
        flow: ImportDraftTestFlow, layout: NativeListTestLayout
    ) async throws {
        let state = ImportDraftTestState(flow: flow)
        let database = try WalletDatabase.temporary()
        let host = try NativeListTestHost(layout: layout) {
            ImportDraftTestPresentation(state: state, database: database, flow: flow)
        }
        defer { host.close() }
        let presentation = try await presentedController(host)
        let navigation = try #require(findNavigation(in: presentation))
        let optionsDepth = flow == .onboarding ? 1 : 2
        try await settle(navigation, depth: optionsDepth)

        // Recovery typing is local. The private-key fixture is deliberately
        // over-limit to avoid its pre-existing remote draft callback.
        let phrase = "invalidphrase"
        let key = String(repeating: "invalid-key-", count: 1_500)

        try await choose(0, rows: 4, host: host, navigation: navigation)
        try await settle(navigation, depth: optionsDepth + 1)
        try await enter(phrase, navigation: navigation)
        try await back(navigation, depth: optionsDepth)
        try await choose(1, rows: 4, host: host, navigation: navigation)
        try await settle(navigation, depth: optionsDepth + 1)
        let networkCount = PrivateKeyImportNetwork.allCases.count
        try await choose(0, rows: networkCount, host: host, navigation: navigation, navigationLink: true)
        try await settle(navigation, depth: optionsDepth + 2)
        try await enter(key, navigation: navigation)
        try await back(navigation, depth: optionsDepth + 1)

        // A different network must never inherit the first network's key.
        try await choose(1, rows: networkCount, host: host, navigation: navigation, navigationLink: true)
        try await settle(navigation, depth: optionsDepth + 2)
        #expect(try await inputIsEmpty(navigation))
        try await back(navigation, depth: optionsDepth + 1)
        try await choose(0, rows: networkCount, host: host, navigation: navigation, navigationLink: true)
        try await settle(navigation, depth: optionsDepth + 2)
        #expect(try await inputIsEmpty(navigation))
        try await back(navigation, depth: optionsDepth + 1)
        try await back(navigation, depth: optionsDepth)
        try await choose(0, rows: 4, host: host, navigation: navigation)
        try await settle(navigation, depth: optionsDepth + 1)
        #expect(try await inputIsEmpty(navigation))
        #expect(host.rootView.window?.rootViewController?.presentedViewController === presentation)
        #expect(presentation.presentedViewController == nil)
        #expect(navigation.presentedViewController == nil)

        state.isPresented = false
        try await SendEntryUIProbe.wait(in: host.rootView) {
            host.rootView.window?.rootViewController?.presentedViewController == nil
        }
        state.path = flow == .onboarding ? [] : [.setup(.importOptions)]
        state.isPresented = true
        let freshPresentation = try await presentedController(host)
        let freshNavigation = try #require(findNavigation(in: freshPresentation))
        try await settle(freshNavigation, depth: optionsDepth)
        try await choose(0, rows: 4, host: host, navigation: freshNavigation)
        try await settle(freshNavigation, depth: optionsDepth + 1)
        #expect(try await inputIsEmpty(freshNavigation))
        #expect(try await database.managedWalletCount() == 0)
    }

    private func enter(_ text: String, navigation: UINavigationController) async throws {
        let editor = try await input(navigation)
        #expect(editor.becomeFirstResponder())
        if let field = editor as? UITextField { field.insertText(text) }
        else if let view = editor as? UITextView { view.insertText(text) }
        try await SendEntryUIProbe.wait(in: navigation.view) { inputText(editor) == text }
        await Task.yield()
        navigation.view.endEditing(true)
    }

    private func input(_ navigation: UINavigationController) async throws -> UIView {
        let view = try #require(navigation.topViewController?.view)
        try await SendEntryUIProbe.wait(in: view) {
            !SendEntryUIProbe.views(UITextField.self, in: view).isEmpty
                || SendEntryUIProbe.views(UITextView.self, in: view).contains { $0.isEditable }
        }
        if let field = SendEntryUIProbe.views(UITextField.self, in: view).first { return field }
        return try #require(SendEntryUIProbe.views(UITextView.self, in: view).first { $0.isEditable })
    }

    private func inputText(_ view: UIView) -> String {
        (view as? UITextField)?.text ?? (view as? UITextView)?.text ?? ""
    }

    private func inputIsEmpty(_ navigation: UINavigationController) async throws -> Bool {
        let editor = try await input(navigation)
        return inputText(editor).isEmpty
            && SendEntryUIProbe.element("recoveryPhraseWord_1", in: navigation.topViewController!.view) == nil
    }

    private func choose(
        _ row: Int, rows: Int, host: NativeListTestHost, navigation: UINavigationController,
        navigationLink: Bool = false
    ) async throws {
        let view = try #require(navigation.topViewController?.view)
        try await SendEntryUIProbe.wait(in: view) {
            SendEntryUIProbe.views(UICollectionView.self, in: view).contains { list in
                (0..<list.numberOfSections).contains { list.numberOfItems(inSection: $0) == rows }
            }
        }
        let list = try #require(SendEntryUIProbe.views(UICollectionView.self, in: view).first)
        let section = try #require((0..<list.numberOfSections).first {
            list.numberOfItems(inSection: $0) == rows
        })
        let indexPath = IndexPath(item: row, section: section)
        if navigationLink {
            // A navigation-only List uses native selection, unlike the
            // import choice buttons and selection-backed backup list.
            try await host.selectNavigationRow(indexPath, in: list)
        } else {
            try await host.selectRow(indexPath, in: list)
        }
    }

    private func back(_ navigation: UINavigationController, depth: Int) async throws {
        #expect(navigation.topViewController?.navigationItem.hidesBackButton == false)
        navigation.view.endEditing(true)
        #expect(navigation.popViewController(animated: true) != nil)
        try await settle(navigation, depth: depth)
    }

    private func settle(
        _ navigation: UINavigationController, depth: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await SendEntryUIProbe.wait(in: navigation.view, sourceLocation: sourceLocation) {
            navigation.viewControllers.count == depth && navigation.transitionCoordinator == nil
        }
    }

    private func presentedController(_ host: NativeListTestHost) async throws -> UIViewController {
        try await SendEntryUIProbe.wait(in: host.rootView) {
            guard let presented = host.rootView.window?.rootViewController?.presentedViewController else {
                return false
            }
            return !presented.isBeingPresented && findNavigation(in: presented) != nil
        }
        return try #require(host.rootView.window?.rootViewController?.presentedViewController)
    }

    private func findNavigation(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap { findNavigation(in: $0) }.first
    }
}

@MainActor
@Observable
private final class ImportDraftTestState {
    var isPresented = true
    var path: [WalletSwitcherNavigationRoute]

    init(flow: ImportDraftTestFlow) {
        path = flow == .onboarding ? [] : [.setup(.importOptions)]
    }
}

private struct ImportDraftTestPresentation: View {
    @Bindable var state: ImportDraftTestState
    let database: WalletDatabase
    let flow: ImportDraftTestFlow

    var body: some View {
        Text("common.done")
            .sheet(isPresented: $state.isPresented) {
                switch flow {
                case .onboarding:
                    OnboardingView(database: database, startAction: .importWallet, usesExistingProfileSecurity: true)
                case .walletSwitcher:
                    WalletSwitcherSheet(
                        database: database, isAppSwitcherPrivacyActive: false,
                        refreshGeneration: UUID(), path: $state.path,
                        onWalletSelected: { _, _ in false }, onWalletAdded: { _ in false },
                        onDismissRequested: { state.isPresented = false },
                        services: WalletSwitcherSetupTestFixtures.services()
                    ) { _ in Text("settings.wallets.title") }
                        .environment(WalletSettingsStore(database: database))
                }
            }
    }
}

import Observation
import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor
@Suite(.serialized)
struct NativeTransientDraftLifetimeTests {
    @Test(arguments: ImportDraftTestFlow.allCases, [NativeListTestLayout.phone, .pad])
    func auxiliaryImportInputsSurviveChildNavigationButNotBackOut(
        flow: ImportDraftTestFlow, layout: NativeListTestLayout
    ) async throws {
        for kind in AuxiliaryImportFixtureKind.allCases {
            let state = TransientDraftFixtureState()
            let host = try NativeListTestHost(layout: layout) {
                AuxiliaryImportDraftFixture(state: state, flow: flow, kind: kind)
            }
            defer { host.close() }
            try await SendEntryUIProbe.wait(in: host.rootView) {
                host.navigationController?.viewControllers.count == 2
            }
            let navigation = try #require(host.navigationController)
            let original = try await auxiliaryField(kind, navigation: navigation, host: host)
            #expect(original.becomeFirstResponder())
            original.insertText("ABCD")
            try await SendEntryUIProbe.wait(in: host.rootView) { original.text == "ABCD" }
            navigation.view.endEditing(true)
            state.path.append(.next)
            try await settle(navigation, depth: 3)
            #expect(navigation.popViewController(animated: true) != nil)
            try await settle(navigation, depth: 2)
            #expect(try await auxiliaryField(kind, navigation: navigation, host: host).text == "ABCD")
            #expect(navigation.popViewController(animated: true) != nil)
            try await settle(navigation, depth: 1)
            state.path.append(.input)
            try await settle(navigation, depth: 2)
            #expect(try await auxiliaryField(kind, navigation: navigation, host: host).text?.isEmpty == true)
        }
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad])
    func closingSendAndOpeningItAgainClearsRecipientAndAmount(layout: NativeListTestLayout) async throws {
        let database = try WalletDatabase.temporary()
        let settings = WalletSettingsStore(database: database)
        let state = TransientDraftFixtureState()
        let host = try NativeListTestHost(layout: layout) {
            SendDraftSheetFixture(state: state, database: database)
                .environment(settings)
            .environment(SendActivityStore())
                .environment(\.walletCurrencyContext, SendEntryTestFixtures.currency)
        }
        defer { host.close() }
        var navigation = try await presentedNavigation(host)
        try await enterRecipient(navigation)
        try SendEntryUIProbe.activate("sendAmountKey1", in: navigation.topViewController!.view)
        state.isPresented = false
        try await SendEntryUIProbe.wait(in: host.rootView) {
            host.rootView.window?.rootViewController?.presentedViewController == nil
        }
        state.isPresented = true
        navigation = try await presentedNavigation(host)
        let view = try #require(navigation.topViewController?.view)
        let input = try #require(SendEntryUIProbe.views(UITextView.self, in: view).first)
        #expect(input.text.isEmpty)
        #expect(SendEntryUIProbe.element("sendRecipientContinue", in: view)?.accessibilityTraits.contains(.notEnabled) == true)
        try await enterRecipient(navigation)
        let amountView = try #require(navigation.topViewController?.view)
        let list = try #require(SendEntryUIProbe.views(UICollectionView.self, in: amountView).first)
        let cell = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
        #expect(SendEntryUIProbe.element("sendAmountValue", in: cell)?.accessibilityValue == "0 ETH")
        #expect(SendEntryUIProbe.element("sendAmountReview", in: amountView)?.accessibilityTraits.contains(.notEnabled) == true)
    }

    private func auxiliaryField(
        _ kind: AuxiliaryImportFixtureKind, navigation: UINavigationController, host: NativeListTestHost
    ) async throws -> UITextField {
        let view = try #require(navigation.topViewController?.view)
        try await SendEntryUIProbe.wait(in: view) {
            !SendEntryUIProbe.views(UICollectionView.self, in: view).isEmpty
        }
        let list = try #require(SendEntryUIProbe.views(UICollectionView.self, in: view).first)
        let section = kind == .encryptedKeys ? 0 : 1
        let cell = try await host.cell(at: IndexPath(item: 0, section: section), in: list)
        return try #require(SendEntryUIProbe.views(UITextField.self, in: cell).first)
    }

    private func enterRecipient(_ navigation: UINavigationController) async throws {
        let view = try #require(navigation.topViewController?.view)
        let input = try #require(SendEntryUIProbe.views(UITextView.self, in: view).first)
        input.text = SendEntryTestFixtures.address(for: .ethereum)
        input.delegate?.textViewDidChange?(input)
        try await SendEntryUIProbe.wait(in: view) {
            SendEntryUIProbe.element("sendRecipientContinue", in: view)?.accessibilityTraits.contains(.notEnabled) == false
        }
        try SendEntryUIProbe.activate("sendRecipientContinue", in: view)
        try await settle(navigation, depth: 3)
    }

    private func presentedNavigation(_ host: NativeListTestHost) async throws -> UINavigationController {
        func find(_ controller: UIViewController) -> UINavigationController? {
            (controller as? UINavigationController) ?? controller.children.lazy.compactMap { find($0) }.first
        }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            guard let presented = host.rootView.window?.rootViewController?.presentedViewController,
                  !presented.isBeingPresented, let navigation = find(presented) else { return false }
            return navigation.viewControllers.count == 2 && navigation.transitionCoordinator == nil
                && SendEntryUIProbe.element("sendRecipientInput", in: presented.view) != nil
        }
        let presented = try #require(host.rootView.window?.rootViewController?.presentedViewController)
        return try #require(find(presented))
    }

    private func settle(_ navigation: UINavigationController, depth: Int) async throws {
        try await SendEntryUIProbe.wait(in: navigation.view) {
            navigation.viewControllers.count == depth && navigation.transitionCoordinator == nil
        }
    }
}

private enum AuxiliaryImportFixtureKind: CaseIterable { case trustPassword, encryptedKeys, emergencyKit }
private enum TransientDraftFixtureRoute: Hashable { case input, next }

@MainActor
@Observable
private final class TransientDraftFixtureState {
    var path: [TransientDraftFixtureRoute] = [.input]
    var isPresented = true
}

private struct AuxiliaryImportDraftFixture: View {
    @Bindable var state: TransientDraftFixtureState
    let flow: ImportDraftTestFlow
    let kind: AuxiliaryImportFixtureKind

    private var backup: TrustWalletBackupDescriptor {
        TrustWalletBackupDescriptor(id: "draft-lifetime", walletName: nil, fileName: "fixture.json",
                                    modifiedAt: nil, kind: .recoveryPhrase, encryptedJSON: Data())
    }

    var body: some View {
        NavigationStack(path: $state.path) {
            Text("common.done")
                .navigationDestination(for: TransientDraftFixtureRoute.self) { route in
                    if route == .next { Text("common.done") } else {
                        switch (flow, kind) {
                        case (.onboarding, .trustPassword):
                            OnboardingTrustWalletPasswordScreen(backup: backup) { _, _ in state.path.append(.next) }
                        case (.walletSwitcher, .trustPassword):
                            WalletSwitcherTrustWalletPasswordScreen(backup: backup) { _, _ in state.path.append(.next) }
                        case (.onboarding, .encryptedKeys):
                            OnboardingMuunEncryptedKeysImportScreen { _ in state.path.append(.next) }
                        case (.walletSwitcher, .encryptedKeys):
                            WalletSwitcherMuunEncryptedKeysImportScreen { _ in state.path.append(.next) }
                        case (.onboarding, .emergencyKit):
                            OnboardingMuunEmergencyKitImportScreen { _ in state.path.append(.next) }
                        case (.walletSwitcher, .emergencyKit):
                            WalletSwitcherMuunEmergencyKitImportScreen { _ in state.path.append(.next) }
                        }
                    }
                }
        }
    }
}

private struct SendDraftSheetFixture: View {
    @Bindable var state: TransientDraftFixtureState
    let database: WalletDatabase

    var body: some View {
        Text("common.done")
            .sheet(isPresented: $state.isPresented) {
                SendFlowView(database: database, walletAddress: NativeListTestFixtures.address,
                             walletAssets: [], preparationRevision: UUID(),
                             initialRoute: SendFlowPlanner.manualEntryRoute(for: SendEntryTestFixtures.ethereum))
            }
    }
}

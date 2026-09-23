import Observation
import SwiftUI
import Testing
import UIKit
@testable import Aperture

/// Native presentation/accessibility assertions, without screenshots or camera
/// injection. The simulator's unavailable-camera state remains dismissible.
@MainActor
@Suite(.serialized)
struct NativeQRScannerPresentationTests {
    @Test(arguments: QRModalFixtureKind.allCases, [NativeListTestLayout.phone, .phoneLandscape, .padLandscape, .largeTextRTL])
    func scannerHasNativeCloseAndReturnsToItsPresenter(
        kind: QRModalFixtureKind, layout: NativeListTestLayout
    ) async throws {
        let database = try WalletDatabase.temporary()
        let settings = WalletSettingsStore(database: database)
        let state = QRModalFixtureState()
        let host = try NativeListTestHost(layout: layout) {
            QRModalFixture(state: state, kind: kind)
                .environment(settings)
        }
        defer { host.close() }
        let root = try #require(host.rootView.window?.rootViewController)
        root.traitOverrides.horizontalSizeClass = layout == .padLandscape ? .regular : .compact
        root.traitOverrides.verticalSizeClass = layout == .phoneLandscape ? .compact : .regular
        state.isPresented = true
        let scanner = try await modal(host)
        let navigation = try #require(findNavigation(scanner))
        #expect(navigation.viewControllers.count == 1)
        let close = try #require(SendEntryUIProbe.element("qrScannerClose", in: scanner.view))
        #expect(close.accessibilityTraits.contains(.button))
        #expect(!close.accessibilityTraits.contains(.notEnabled))
        #expect(!close.accessibilityFrame.isEmpty)
        let closeFrame = scanner.view.convert(close.accessibilityFrame, from: nil)
        #expect(scanner.view.bounds.intersects(closeFrame))
        if layout == .phoneLandscape {
            let presentation = try #require(scanner.presentationController)
            let container = try #require(presentation.containerView)
            #expect(abs(presentation.frameOfPresentedViewInContainerView.height - container.bounds.height) < 1)
        } else if let sheet = scanner.sheetPresentationController {
            #expect(sheet.detents.map(\.identifier) == [.large])
        }
        try NativeQRScannerUIProbe.close(scanner)
        try await SendEntryUIProbe.wait(in: host.rootView) { root.presentedViewController == nil }
        #expect(!state.isPresented)
        #expect(state.resultCount == 0)
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad])
    func tokenLookupScannerIsModalAndClosingPreservesInput(layout: NativeListTestLayout) async throws {
        let database = try WalletDatabase.temporary()
        let settings = WalletSettingsStore(database: database)
        let network = try #require(ReceiveNetworkCatalog.all.first { $0.id == "eth" })
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                AddTokenContractLookupView(database: database, network: network) { _ in
                    Issue.record("Closing the scanner must not add a token")
                }
            }
            .environment(settings)
        }
        defer { host.close() }
        let list = try await host.list()
        let cell = try await host.cell(at: IndexPath(item: 0, section: 0), in: list)
        let input = try #require(SendEntryUIProbe.views(UITextField.self, in: cell).first)
        #expect(input.becomeFirstResponder())
        input.insertText("0x1234") // Incomplete contract; no provider lookup.
        let actions = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
        try SendEntryUIProbe.activate("tokenContractScan", in: actions)
        let scanner = try await modal(host)
        #expect(host.navigationController?.viewControllers.count == 1)
        try NativeQRScannerUIProbe.close(scanner)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            host.rootView.window?.rootViewController?.presentedViewController == nil
        }
        let restoredCell = try await host.cell(at: IndexPath(item: 0, section: 0), in: list)
        #expect(SendEntryUIProbe.views(UITextField.self, in: restoredCell).first?.text == "0x1234")
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad])
    func deviceTransferScannerIsModalAndCloseDoesNotStartImport(layout: NativeListTestLayout) async throws {
        let database = try WalletDatabase.temporary()
        let settings = WalletSettingsStore(database: database)
        let host = try NativeListTestHost(layout: layout) {
            OnboardingView(database: database, startAction: .importWallet)
                .environment(settings)
        }
        defer { host.close() }
        let list = try await host.list { list in
            (0..<list.numberOfSections).contains { list.numberOfItems(inSection: $0) == 5 }
        }
        let section = try #require((0..<list.numberOfSections).first { list.numberOfItems(inSection: $0) == 5 })
        let navigation = try #require(host.navigationController)
        let initialDepth = navigation.viewControllers.count
        try await host.selectRow(IndexPath(item: 4, section: section), in: list)
        let scanner = try await modal(host)
        #expect(navigation.viewControllers.count == initialDepth)
        try NativeQRScannerUIProbe.close(scanner)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            host.rootView.window?.rootViewController?.presentedViewController == nil
        }
        #expect(navigation.viewControllers.count == initialDepth)
        #expect(try await database.managedWalletCount() == 0)
    }

    private func modal(_ host: NativeListTestHost) async throws -> UIViewController {
        try await SendEntryUIProbe.wait(in: host.rootView) {
            guard let sheet = host.rootView.window?.rootViewController?.presentedViewController else { return false }
            return !sheet.isBeingPresented && sheet.transitionCoordinator == nil
                && SendEntryUIProbe.element("qrScannerClose", in: sheet.view) != nil
        }
        return try #require(host.rootView.window?.rootViewController?.presentedViewController)
    }

    private func findNavigation(_ controller: UIViewController) -> UINavigationController? {
        (controller as? UINavigationController) ?? controller.children.lazy.compactMap { findNavigation($0) }.first
    }
}

enum QRModalFixtureKind: CaseIterable {
    case onboardingCredential, switcherCredential, homeAddress, recipient, tokenContract, bitcoinTransaction, deviceTransfer
}

/// Invoke the native bar item's public target/action. UIBarButtonItem's system
/// Close control does not implement UIView.accessibilityActivate in this host.
@MainActor
enum NativeQRScannerUIProbe {
    static func close(_ controller: UIViewController) throws {
        let navigation = try #require(navigationController(in: controller))
        let item = try #require(navigation.topViewController?.navigationItem)
        let buttons = item.leadingItemGroups.flatMap(\.barButtonItems)
            + (item.leftBarButtonItems ?? [])
        let close = try #require(buttons.first { button in
            button.accessibilityIdentifier == "qrScannerClose"
                || button.customView.map {
                    SendEntryUIProbe.element("qrScannerClose", in: $0) != nil
                } == true
        })
        #expect(close.isEnabled)
        if let action = close.action {
            #expect(UIApplication.shared.sendAction(action, to: close.target, from: close, for: nil))
        } else {
            try SendEntryUIProbe.activate("qrScannerClose", in: navigation.view)
        }
    }

    private static func navigationController(in controller: UIViewController) -> UINavigationController? {
        (controller as? UINavigationController)
            ?? controller.children.lazy.compactMap { navigationController(in: $0) }.first
    }
}

@MainActor
@Observable
private final class QRModalFixtureState {
    var isPresented = false
    var resultCount = 0
}

private struct QRModalFixture: View {
    @Bindable var state: QRModalFixtureState
    let kind: QRModalFixtureKind

    var body: some View {
        Text("common.done")
            .sheet(isPresented: $state.isPresented) {
                scanner
                    .walletScannerPresentation()
            }
    }

    @ViewBuilder
    private var scanner: some View {
        switch kind {
        case .onboardingCredential:
            ImportWalletCredentialScannerScreen(mode: .recoveryPhrase) { _ in state.resultCount += 1 }
        case .switcherCredential:
            WalletSwitcherCredentialScannerScreen(mode: .recoveryPhrase) { _ in state.resultCount += 1 }
        case .homeAddress:
            WalletAddressScannerScreen(prepareRequest: { _ in .failed(WalletLocalization.string("send.error.network_not_available_in_wallet")) }) { _ in state.resultCount += 1 }
        case .recipient:
            NavigationStack {
                SendRecipientScannerScreen(asset: SendEntryTestFixtures.ethereum) { _ in state.resultCount += 1 }
            }
        case .tokenContract:
            NavigationStack {
                AddTokenContractScannerView(network: ReceiveNetworkCatalog.all.first { $0.id == "eth" }!) { _ in
                    state.resultCount += 1
                    return true
                }
            }
        case .bitcoinTransaction:
            NavigationStack { BitcoinTransactionQRScannerView { _ in state.resultCount += 1 } }
        case .deviceTransfer:
            NavigationStack { DeviceMigrationScannerScreen { _ in state.resultCount += 1 } }
        }
    }
}

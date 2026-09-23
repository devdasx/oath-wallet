import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor
@Suite(.serialized)
struct TextInputPresentationFocusTests {
    @Test(arguments: ["recovery", "switcherRecovery", "privateKey", "switcherPrivateKey", "genericPrivateKey", "switcherGenericPrivateKey", "passphrase", "switcherPassphrase", "creationPassphrase", "physicalPassphrase", "switcherCreationPassphrase", "muunKeys", "muunPDF", "sendText", "wordList", "filter", "transaction"], [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func onlyExplicitCredentialScreensRequestInitialFocus(screen: String, layout: NativeListTestLayout) async throws {
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack { destination(screen) }
        }
        defer { host.close() }
        _ = try #require(host.rootView.window)
        let shouldFocus = ["recovery", "switcherRecovery", "privateKey",
                           "switcherPrivateKey", "genericPrivateKey", "switcherGenericPrivateKey",
                           "passphrase", "switcherPassphrase", "creationPassphrase",
                           "physicalPassphrase", "switcherCreationPassphrase"].contains(screen)
        // Observe the actual presentation lifecycle, rather than the presence
        // of a FocusState binding. Only credential entry explicitly opts in.
        try await Task.sleep(for: .milliseconds(450))
        if shouldFocus {
            try await SendEntryUIProbe.wait(in: host.rootView) {
                inputs(in: host.rootView).contains(where: \.isFirstResponder)
            }
        }
        host.rootView.layoutIfNeeded()
        let fields = inputs(in: host.rootView)
        let initiallyFocused = fields.contains { $0.isFirstResponder }
        #expect(initiallyFocused == shouldFocus, "Unexpected initial focus for \(screen)")
        // Native lists may retain offscreen fields; manual interaction only
        // targets a field currently inside the visible viewport.
        if screen != "wordList", let input = fields.first(where: {
            $0.window != nil && host.rootView.bounds.intersects($0.convert($0.bounds, to: host.rootView))
        }) {
            #expect(input.becomeFirstResponder(), "User-initiated editing remains available")
            host.rootView.layoutIfNeeded()
            await Task.yield()
            #expect(input.isFirstResponder)
        }
        host.rootView.endEditing(true)
        host.rootView.setNeedsLayout()
        host.rootView.layoutIfNeeded()
        await Task.yield()
        let remainsFocused = inputs(in: host.rootView).contains { $0.isFirstResponder }
        #expect(!remainsFocused)
    }

    @Test(arguments: [NativeListTestLayout.phone, .phoneLandscape, .pad, .padLandscape, .largeTextRTL])
    func homeCurrencySearchWaitsForInteraction(layout: NativeListTestLayout) async throws {
        let query = ListActionRecorder<String>()
        let binding = Binding<String>(get: { query.actions.last ?? "" }, set: { query.actions.append($0) })
        let host = try NativeListTestHost(layout: layout) {
            WalletHomeCurrencyNavigationContainer(searchText: binding, onBack: {}) {
                List { Text("settings.currency.title") }
            }
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            host.navigationController?.topViewController?.navigationItem.searchController != nil
        }
        try await Task.sleep(for: .milliseconds(600))
        let navigation = try #require(host.navigationController)
        let search = try #require(navigation.topViewController?.navigationItem.searchController)
        #expect(!search.isActive)
        #expect(!search.searchBar.searchTextField.isFirstResponder)

        // The search remains fully usable after explicit activation.
        search.isActive = true
        #expect(search.searchBar.searchTextField.becomeFirstResponder())
        search.searchBar.searchTextField.insertText("EUR")
        search.searchResultsUpdater?.updateSearchResults(for: search)
        #expect(binding.wrappedValue == "EUR")
        search.searchBar.delegate?.searchBarSearchButtonClicked?(search.searchBar)
        #expect(!search.searchBar.searchTextField.isFirstResponder)
        navigation.view.setNeedsLayout()
        navigation.view.layoutIfNeeded()
        await Task.yield()
        #expect(!search.searchBar.searchTextField.isFirstResponder)
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func tokenContractLookupWaitsForInteraction(layout: NativeListTestLayout) async throws {
        let database = try WalletDatabase.temporary()
        let network = try #require(ReceiveNetworkCatalog.network(for: .ethereum))
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                AddTokenContractLookupView(database: database, network: network) { _ in }
            }
        }
        defer { host.close() }
        _ = try await host.list()
        try await Task.sleep(for: .milliseconds(450))
        let input = try #require(inputs(in: host.rootView).first)
        #expect(!input.isFirstResponder)
        #expect(input.becomeFirstResponder())
        host.rootView.endEditing(true)
        host.rootView.layoutIfNeeded()
        await Task.yield()
        #expect(!input.isFirstResponder)
    }

    @ViewBuilder
    private func destination(_ name: String) -> some View {
        switch name {
        case "recovery": ImportWalletCredentialView(credential: .recoveryPhrase) { _ in }
        case "switcherRecovery": WalletSwitcherRecoveryImportScreen(credential: .recoveryPhrase) { _ in }
        case "privateKey": PrivateKeyCredentialView(network: .evm) { _ in }
        case "switcherPrivateKey": WalletSwitcherPrivateKeyImportScreen(network: .evm) { _ in }
        case "genericPrivateKey": ImportWalletCredentialView(credential: .privateKey) { _ in }
        case "switcherGenericPrivateKey": WalletSwitcherRecoveryImportScreen(credential: .privateKey) { _ in }
        case "passphrase": ImportWalletRecoveryPassphraseScreen(initialPassphrase: "") { _ in }
        case "switcherPassphrase": WalletSwitcherImportPassphraseScreen(initialPassphrase: "") { _ in }
        case "creationPassphrase": SettingsWalletCreationPassphraseScreen(initialPassphrase: "") { _ in }
        case "switcherCreationPassphrase": WalletSwitcherCreationPassphraseScreen(initialPassphrase: "") { _ in }
        case "physicalPassphrase": OnboardingPhysicalEntropyPassphraseScreen(initialPassphrase: "") { _ in }
        case "muunKeys": OnboardingMuunEncryptedKeysImportScreen { _ in }
        case "muunPDF": OnboardingMuunEmergencyKitImportScreen { _ in }
        case "sendText": SendTextAddressScreen(prepareRequest: { _ in .failed("unused-test-action") }, onProceed: { _ in })
        case "transaction": WalletTransactionDetailsView(transaction: WalletTransaction(
            id: "initial-focus-test", kind: .sent(assetSymbol: "ETH"), detail: "", time: "",
            assetLogoSource: .nativeCoin(blockchain: .ethereum), assetAmount: 1,
            assetSymbol: "ETH", fiatValue: nil, status: .confirmed
        ), isBalanceHidden: false)
        case "filter": WalletActivityFilterView(filter: WalletActivityFilter(), availableNetworks: [], availableDateRange: nil) { _ in }
        default: OnboardingPhysicalEntropyWordListScreen()
        }
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func transactionNoteUsesNativeSingleLineInput(layout: NativeListTestLayout) async throws {
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack { destination("transaction") }
        }
        defer { host.close() }
        let list = try await host.list { $0.numberOfSections == 4 }
        let cell = try await host.cell(at: IndexPath(item: 0, section: 3), in: list)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            !SendEntryUIProbe.views(UITextField.self, in: cell).isEmpty
        }
        let field = try #require(SendEntryUIProbe.views(UITextField.self, in: cell).first)
        #expect(!field.isFirstResponder)
        #expect(SendEntryUIProbe.views(UITextView.self, in: cell).isEmpty)
        #expect(field.becomeFirstResponder())
        let note = String(repeating: "Local transaction note. ", count: 8)
        field.insertText(note)
        #expect(field.text == note)
        host.rootView.endEditing(true)
    }

    private func inputs(in root: UIView) -> [UIView] {
        let fields: [UIView] = SendEntryUIProbe.views(UITextField.self, in: root).filter { !$0.isHidden && $0.isEnabled }
        let editors: [UIView] = SendEntryUIProbe.views(UITextView.self, in: root).filter { !$0.isHidden && $0.isEditable }
        // A SwiftUI multiline text field may embed a UITextView. Only the actual
        // editable responder belongs in the ordering check.
        return fields + editors
    }
}

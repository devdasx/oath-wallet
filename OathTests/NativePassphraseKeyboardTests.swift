import SwiftUI
import Testing
import UIKit
@testable import Aperture

/// Native secure fields with public dummy strings; saving records in memory only.
@MainActor
@Suite(.serialized)
struct NativePassphraseKeyboardTests {
    enum Flow: String, CaseIterable {
        case importRecovery, switcherImport, settingsCreation, onboardingEntropy, switcherCreation

        @MainActor @ViewBuilder
        func screen(saved: ListActionRecorder<String>) -> some View {
            switch self {
            case .importRecovery:
                ImportWalletRecoveryPassphraseScreen(initialPassphrase: "") { saved.actions.append($0) }
            case .switcherImport:
                WalletSwitcherImportPassphraseScreen(initialPassphrase: "") { saved.actions.append($0) }
            case .settingsCreation:
                SettingsWalletCreationPassphraseScreen(initialPassphrase: "") { saved.actions.append($0) }
            case .onboardingEntropy:
                OnboardingPhysicalEntropyPassphraseScreen(initialPassphrase: "") { saved.actions.append($0) }
            case .switcherCreation:
                WalletSwitcherCreationPassphraseScreen(initialPassphrase: "") { saved.actions.append($0) }
            }
        }
    }

    @Test(arguments: Flow.allCases, [NativeListTestLayout.phone, .padLandscape, .largeTextRTL])
    func nextFocusesVerificationAndDoneOnlyDismisses(flow: Flow, layout: NativeListTestLayout) async throws {
        let saved = ListActionRecorder<String>()
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack { flow.screen(saved: saved) }
                .walletTextInputConfiguration(layout.direction)
        }
        defer { host.close() }
        let first = try await focusedField(flow.rawValue + "Passphrase", host: host)
        #expect(first.isSecureTextEntry)
        #expect(first.returnKeyType == .next)
        first.insertText("public passphrase")
        try await SendEntryUIProbe.wait(in: host.rootView) { first.text == "public passphrase" }
        #expect(first.delegate?.textFieldShouldReturn?(first) == false)

        let confirmation = try await focusedField(flow.rawValue + "Confirmation", host: host)
        #expect(confirmation.isSecureTextEntry)
        #expect(confirmation.text?.isEmpty != false)
        #expect(confirmation.returnKeyType == .done)
        #expect(saved.actions.isEmpty)
        // Done dismisses even an empty verification field; it never saves.
        #expect(confirmation.delegate?.textFieldShouldReturn?(confirmation) == false)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            !first.isFirstResponder && !confirmation.isFirstResponder
        }
        #expect(saved.actions.isEmpty)

        #expect(confirmation.becomeFirstResponder())
        confirmation.insertText("public passphrase")
        try await SendEntryUIProbe.wait(in: host.rootView) {
            confirmation.text == "public passphrase" && saveItem(host)?.isEnabled == true
        }
        #expect(confirmation.delegate?.textFieldShouldReturn?(confirmation) == false)
        try await SendEntryUIProbe.wait(in: host.rootView) { !confirmation.isFirstResponder }
        #expect(saved.actions.isEmpty)
        // Layout updates must not steal focus back after Done.
        host.rootView.setNeedsLayout()
        host.rootView.layoutIfNeeded()
        await Task.yield()
        #expect(!first.isFirstResponder && !confirmation.isFirstResponder)

        let save = try #require(saveItem(host))
        #expect(save.title?.isEmpty != false)
        let action = try #require(save.action)
        #expect(UIApplication.shared.sendAction(action, to: save.target, from: save, for: nil))
        try await SendEntryUIProbe.wait(in: host.rootView) { saved.actions == ["public passphrase"] }
    }

    @Test
    func submitExceptionExpiresWithItsOwnerAndDoesNotFollowAReusedField() throws {
        let host = try NativeListTestHost { Color.clear }
        defer { host.close() }
        let field = UITextField(frame: CGRect(x: 20, y: 120, width: 200, height: 44))
        let anchor = UIView(frame: field.frame)
        anchor.isUserInteractionEnabled = false
        host.rootView.addSubview(anchor)
        host.rootView.addSubview(field)
        var returns = 0
        var action: WalletTextInputReturnKey.SubmitAction? = .init(
            returnKeyType: .next
        )
        action?.anchor = anchor
        action?.perform = { returns += 1 }
        WalletTextInputReturnKey.install(try #require(action), on: field)
        WalletTextInputReturnKey.install(on: field)
        #expect(field.returnKeyType == .next)
        #expect(field.delegate?.textFieldShouldReturn?(field) == false)
        #expect(returns == 1)

        field.frame.origin.y = 300
        WalletTextInputReturnKey.install(on: field)
        #expect(field.returnKeyType == .done)
        #expect(field.delegate?.textFieldShouldReturn?(field) == false)
        #expect(returns == 1)

        field.frame = anchor.frame
        action = nil
        WalletTextInputReturnKey.install(on: field)
        #expect(field.returnKeyType == .done)
        #expect(field.delegate?.textFieldShouldReturn?(field) == false)
        #expect(returns == 1)
    }

    private func focusedField(
        _ identifier: String, host: NativeListTestHost, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> UITextField {
        do {
            try await SendEntryUIProbe.wait(in: host.rootView, sourceLocation: sourceLocation) {
                let fields = SendEntryUIProbe.views(UITextField.self, in: host.rootView)
                let index = identifier.hasSuffix("Confirmation") ? 1 : 0
                return fields.indices.contains(index) && fields[index].isFirstResponder
            }
        } catch {
            let fields = SendEntryUIProbe.views(UITextField.self, in: host.rootView).map {
                "\($0.accessibilityIdentifier ?? "no identifier"): focused=\($0.isFirstResponder), return=\($0.returnKeyType.rawValue)"
            }
            Issue.record("Expected \(identifier); native fields: \(fields)", sourceLocation: sourceLocation)
            throw error
        }
        let fields = SendEntryUIProbe.views(UITextField.self, in: host.rootView)
        return try #require(fields.first { $0.isFirstResponder })
    }

    private func saveItem(_ host: NativeListTestHost) -> UIBarButtonItem? {
        guard let item = host.navigationController?.topViewController?.navigationItem else { return nil }
        return item.trailingItemGroups.flatMap(\.barButtonItems).first ?? item.rightBarButtonItems?.first
    }
}

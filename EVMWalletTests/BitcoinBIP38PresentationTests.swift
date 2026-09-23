import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor
@Suite(.serialized)
struct BitcoinBIP38PresentationTests {
    @Test(arguments: [false, true], [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func detectsEncryptedKeyAndPresentsNativeSecurePasswordAlert(
        switcher: Bool, layout: NativeListTestLayout
    ) async throws {
        let fixture = try #require(BitcoinBIP38Tests.vectors.last)
        var importCount = 0
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                if switcher {
                    WalletSwitcherPrivateKeyImportScreen(network: .bitcoin, initialInput: fixture.encrypted) { _ in importCount += 1 }
                } else {
                    PrivateKeyCredentialView(network: .bitcoin, initialInput: fixture.encrypted) { _ in importCount += 1 }
                }
            }
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) { dialog(in: host) != nil }
        let alert = try #require(dialog(in: host))
        #expect(alert.preferredStyle == .alert)
        #expect(alert.textFields?.count == 1)
        #expect(alert.textFields?.first?.isSecureTextEntry == true)
        let passwordField = try #require(alert.textFields?.first)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            !alert.isBeingPresented && passwordField.window != nil
        }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            passwordField.isFirstResponder || passwordField.becomeFirstResponder()
        }
        passwordField.insertText("public invalid password")
        try await SendEntryUIProbe.wait(in: host.rootView) {
            passwordField.returnKeyType == .done
        }
        #expect(passwordField.delegate?.textFieldShouldReturn?(passwordField) == false)
        try await SendEntryUIProbe.wait(in: host.rootView) { !passwordField.isFirstResponder }
        #expect(importCount == 0)
        let bundle = WalletAppLanguage.localizedBundle(for: layout.direction == .rightToLeft ? "ar" : "en")
        #expect(alert.actions.contains {
            $0.title == bundle.localizedString(forKey: "common.cancel", value: nil, table: nil) && $0.style == .cancel
        })
        #expect(alert.actions.contains {
            $0.title == bundle.localizedString(forKey: "import.bip38.decrypt", value: nil, table: nil)
        })
        #expect(importCount == 0)
        await withCheckedContinuation { continuation in
            alert.dismiss(animated: false) { continuation.resume() }
        }
        #expect(importCount == 0)
    }

    @Test(arguments: [false, true])
    func decryptActionImportsOnceWithoutAnotherImportTap(switcher: Bool) async throws {
        let fixture = try #require(BitcoinBIP38Tests.vectors.last)
        var imported: [WalletImportDraft] = []
        let host = try NativeListTestHost {
            NavigationStack {
                if switcher {
                    WalletSwitcherPrivateKeyImportScreen(network: .bitcoin, initialInput: fixture.encrypted) { imported.append($0) }
                } else {
                    PrivateKeyCredentialView(network: .bitcoin, initialInput: fixture.encrypted) { imported.append($0) }
                }
            }
        }
        defer { host.close() }
        do {
            try await SendEntryUIProbe.wait(in: host.rootView) { dialog(in: host) != nil }
            let alert = try #require(dialog(in: host))
            let field = try #require(alert.textFields?.first)
            field.becomeFirstResponder()
            field.insertText(fixture.password)
            field.sendActions(for: .editingChanged)
            field.resignFirstResponder()
            await Task.yield()
            let label = WalletAppLanguage.localizedBundle(for: "en")
                .localizedString(forKey: "import.bip38.decrypt", value: nil, table: nil)
            let action = try #require(alert.actions.first { $0.title == label })
            // UIKit's hosted alert action view does not implement accessibilityActivate.
            // Exercise the real installed action before dismissal clears the field;
            // no decryption or import callbacks are substituted by this test.
            typealias AlertHandler = @convention(block) (UIAlertAction) -> Void
            let block = try #require(action.value(forKey: "handler"))
            let handler = unsafeBitCast(block as AnyObject, to: AlertHandler.self)
            handler(action)
            if alert.presentingViewController != nil {
                await withCheckedContinuation { continuation in
                    alert.dismiss(animated: false) { continuation.resume() }
                }
            }

        }
        try await SendEntryUIProbe.wait(in: host.rootView) { !imported.isEmpty }
        #expect(imported.count == 1)
        let expected = try PrivateKeyImportService.importKey(fixture.wif, network: .bitcoin)
        #expect(imported.first?.address == expected.address)
        #expect(imported.first?.publicKey == expected.publicKey)
    }

    private func dialog(in host: NativeListTestHost) -> UIAlertController? {
        var controller = host.rootView.window?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller as? UIAlertController
    }
}

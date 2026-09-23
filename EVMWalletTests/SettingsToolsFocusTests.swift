import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor
@Suite(.serialized)
struct SettingsToolsFocusTests {
    @Test(arguments: [false, true], [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func inputFocusesOnOpeningAndStaysDismissedAfterEditingEnds(
        recoveryWordTool: Bool,
        layout: NativeListTestLayout
    ) async throws {
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                if recoveryWordTool {
                    MnemonicLastWordFinderView()
                } else {
                    BitcoinTransactionBroadcastView()
                }
            }
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            inputs(in: host).contains(where: \.isFirstResponder)
        }
        let focused = inputs(in: host).first { $0.isFirstResponder }
        let input = try #require(focused)
        // Invalid public fixture text only; never a recovery phrase or transaction.
        if let textView = input as? UITextView {
            textView.insertText("invalid")
        } else if let textField = input as? UITextField {
            textField.insertText("invalid")
        }
        host.rootView.endEditing(true)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            !inputs(in: host).contains(where: \.isFirstResponder)
        }
        // Native List can unmount rows while scrolling. Remounting the input
        // must not reopen the keyboard after the user explicitly dismisses it.
        let list = try await host.list()
        list.reloadData()
        host.rootView.layoutIfNeeded()
        await Task.yield()
        let remainsFocused = inputs(in: host).contains { $0.isFirstResponder }
        #expect(!remainsFocused)
    }

    private func inputs(in host: NativeListTestHost) -> [UIView] {
        SendEntryUIProbe.views(UITextView.self, in: host.rootView).map { $0 as UIView }
            + SendEntryUIProbe.views(UITextField.self, in: host.rootView).map { $0 as UIView }
    }
}

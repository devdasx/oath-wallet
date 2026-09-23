import SwiftUI
import UIKit

struct KeyboardReturnFixtureScreen: View {
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var text = ProcessInfo.processInfo.environment["RETURN_TEXT"] ?? ""
    @State private var confirmation = ""
    @State private var submissions = 0
    @State private var saves = 0
    @State private var searchPresented = false
    @State private var alertPresented = false
    @FocusState private var focused: Field?

    private enum Field: Hashable { case first, second }
    private var control: String { ProcessInfo.processInfo.environment["RETURN_CONTROL"] ?? "multiline" }

    var body: some View {
        NavigationStack {
            List {
                if control == "multiline" {
                    TextField("send.recipient.placeholder", text: $text, axis: .vertical)
                        .lineLimit(3...5)
                        .walletTextInputDirection()
                        .focused($focused, equals: .first)
                        .accessibilityIdentifier("return.input")
                } else if control == "secure" {
                    SecureField("import.recovery.passphrase.field", text: $text)
                        .walletTextInputDirection()
                        .focused($focused, equals: .first)
                        .accessibilityIdentifier("return.input")
                    SecureField("import.recovery.passphrase.confirm_field", text: $confirmation)
                        .walletTextInputDirection()
                        .focused($focused, equals: .second)
                        .accessibilityIdentifier("return.confirmation")
                } else if control == "single" || control == "number" {
                    TextField("send.recipient.placeholder", text: $text)
                        .walletTextInputDirection()
                        .keyboardType(control == "number" ? .asciiCapableNumberPad : .default)
                        .focused($focused, equals: .first)
                        .accessibilityIdentifier("return.input")
                }

                // Test data/status only; identifiers are stable across locales.
                Text(verbatim: text).accessibilityIdentifier("return.text")
                Text(verbatim: String(submissions)).accessibilityIdentifier("return.submissions")
                Text(verbatim: String(saves)).accessibilityIdentifier("return.saves")
                Text(verbatim: focused == nil ? "0" : "1").accessibilityIdentifier("return.focused")
                Button("common.save") { saves += 1 }
                    .accessibilityIdentifier("return.save")
            }
            .modifier(SearchFixtureModifier(
                enabled: control == "search", text: $text, presented: $searchPresented
            ))
            .navigationTitle("send.recipient_details.title")
            .alert("settings.wallets.rename.title", isPresented: $alertPresented) {
                TextField("settings.wallets.rename.placeholder", text: $text)
                    .walletTextInputDirection()
                    .accessibilityIdentifier("return.alert.input")
                Button("common.save") { saves += 1 }
                Button("common.cancel", role: .cancel) {}
            }
        }
        // Mimics the production app root, including native alert/search fields.
        .walletTextInputConfiguration(layoutDirection)
        .onSubmit { submissions += 1 }
        .task {
            if let paste = ProcessInfo.processInfo.environment["RETURN_PASTE"] {
                UIPasteboard.general.setItems(
                    [["public.utf8-plain-text": paste]], options: [.localOnly: true]
                )
            }
            if control == "alert" { alertPresented = true }
        }
    }
}

private struct SearchFixtureModifier: ViewModifier {
    let enabled: Bool
    @Binding var text: String
    @Binding var presented: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .searchable(text: $text, isPresented: $presented, prompt: "wallet.home.search.short_prompt")
                .walletTextInputDirection()
        } else { content }
    }
}

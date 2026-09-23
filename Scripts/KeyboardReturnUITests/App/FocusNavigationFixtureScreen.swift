import SwiftUI

struct FocusNavigationFixtureScreen: View {
    @State private var sheet = false
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("common.continue") { FocusEditorFixtureScreen() }
                    .accessibilityIdentifier("focus.push")
                Button("common.edit") { sheet = true }
                    .accessibilityIdentifier("focus.sheet")
            }
        }
        .sheet(isPresented: $sheet) { NavigationStack { FocusEditorFixtureScreen() } }
    }
}

private struct FocusEditorFixtureScreen: View {
    @State private var first = ""
    @State private var second = ""
    @State private var updates = 0
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Int?

    var body: some View {
        List {
            TextField("import.recovery.passphrase.field", text: $first)
                .walletTextInputDirection().focused($focus, equals: 1)
                .accessibilityIdentifier("focus.first")
            SecureField("import.recovery.passphrase.confirm_field", text: $second)
                .walletTextInputDirection().focused($focus, equals: 2)
                .accessibilityIdentifier("focus.second")
            Button("common.edit") { updates += 1 }
                .accessibilityIdentifier("focus.update")
            Text(verbatim: String(updates)).accessibilityIdentifier("focus.updates")
        }
        .navigationTitle("import.recovery.passphrase.navigation")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .close) { dismiss() }.accessibilityIdentifier("focus.close")
            }
        }
    }
}

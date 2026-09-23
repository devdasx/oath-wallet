import SwiftUI

@main
struct DeleteFixtureApp: App {
    var body: some Scene { WindowGroup { DeleteFixtureScreen() } }
}

private struct DeleteFixtureScreen: View {
    // Synthetic input only; this host has no wallet, persistence or networking.
    @State private var state: RecoveryPhraseEditorState
    @State private var focused = true
    @State private var baseline = ""

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let words = "head good wolf hand goat gadget yard ice oak jacket table vacant "
        let phrase = arguments.contains("--complete")
            ? Array(repeating: "abandon", count: 11).joined(separator: " ") + " about "
            : (arguments.contains("--24") ? words + words : words)
        _focused = State(initialValue: !arguments.contains("--dismissed"))
        _state = State(initialValue: RecoveryPhraseEditorState(
            input: arguments.contains("--fragment") ? String(phrase.dropLast()) : phrase
        ))
    }

    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--baseline") {
            TextField("", text: $baseline).accessibilityIdentifier("baseline")
            Text(verbatim: baseline).accessibilityIdentifier("baselineValue")
        } else {
            ScrollView {
                RecoveryPhraseEditor(state: $state, isFocused: $focused) { _ in }
                    .padding(28)
                Text(verbatim: String(state.words.count) + ":" + state.fragment)
                    .accessibilityIdentifier("remaining")
            }
        }
    }
}

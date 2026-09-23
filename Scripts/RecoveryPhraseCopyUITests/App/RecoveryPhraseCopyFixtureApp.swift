import SwiftUI
import UIKit

/// An isolated simulator app: no wallet, Keychain, database, or network access.
/// Only synthetic, deliberately invalid recovery words are ever copied.
@main
struct RecoveryPhraseCopyFixtureApp: App {
    var body: some Scene {
        WindowGroup { RecoveryPhraseCopyFixtureScreen() }
    }
}

struct RecoveryPhraseCopyFixtureScreen: View {
    private let options = ProcessInfo.processInfo.environment
    @State private var revision = 0
    @State private var clipboardMatches = false
    @State private var clipboardChanges = 0

    private var words: [String] {
        (1...(options["COPY_SCREEN"] == "entropy" ? 24 : 12)).map {
            "fixture-\(revision)-\($0)"
        }
    }

    var body: some View {
        NavigationStack {
            screen
                .toolbar {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button("common.retry") { revision += 1 }
                            .accessibilityIdentifier("copy.fixture.changeWords")
                        Text(verbatim: clipboardMatches ? "1" : "0")
                            .accessibilityIdentifier("copy.fixture.matches")
                        Text(verbatim: String(clipboardChanges))
                            .accessibilityIdentifier("copy.fixture.changes")
                    }
                }
        }
        .dynamicTypeSize(options["COPY_LARGE_TEXT"] == "1" ? .accessibility3 : .large)
        .preferredColorScheme(options["COPY_DARK"] == "1" ? .dark : .light)
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            clipboardMatches = UIPasteboard.general.string == words.joined(separator: " ")
            clipboardChanges += 1
        }
    }

    @ViewBuilder
    private var screen: some View {
        switch options["COPY_SCREEN"] {
        case "entropy":
            OnboardingPhysicalEntropyRecoveryScreen(
                words: words, hasPassphrase: false, isSaving: false,
                onManagePassphrase: {}, onViewWordList: {}, onContinue: {}
            )
        case "display":
            WalletRecoveryPhraseDisplayScreen(words: words, passphrase: "")
        default:
            SettingsWalletCreationRecoveryScreen(
                words: words, hasPassphrase: false, isSaving: false,
                onManagePassphrase: {}, onContinue: {}
            )
        }
    }
}

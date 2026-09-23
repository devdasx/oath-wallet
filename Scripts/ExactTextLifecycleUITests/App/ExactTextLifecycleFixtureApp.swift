import SwiftUI

// Only public synthetic identifiers and the production text renderer. No
// wallet storage, credentials, RPCs, analytics, or screenshots in this fixture.
@main
struct ExactTextLifecycleFixtureApp: App {
    var body: some Scene {
        WindowGroup { ExactTextLifecycleFixtureScreen() }
    }
}

enum WalletTheme {
    static let primaryLabel = Color(uiColor: .label)
}

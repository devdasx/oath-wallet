import SwiftUI

/// A separate simulator-only host. It has no wallet, Keychain, database, or
/// network code and is never linked into the Aperture shipping app.
@main
struct KeyboardReturnFixtureApp: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.environment["FOCUS_NAVIGATION"] == "1" {
                FocusNavigationFixtureScreen()
            } else {
                KeyboardReturnFixtureScreen()
            }
        }
    }
}

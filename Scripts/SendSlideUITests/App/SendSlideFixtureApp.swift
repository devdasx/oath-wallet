import SwiftUI

@main
struct SendSlideFixtureApp: App {
    var body: some Scene {
        WindowGroup {
            Color.clear.sheet(isPresented: .constant(true)) {
                SendSlideFixtureScreen()
                    .interactiveDismissDisabled()
                    .presentationBackground(WalletTheme.groupedBackground)
            }
        }
    }
}

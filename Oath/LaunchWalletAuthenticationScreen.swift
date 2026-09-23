import SwiftUI

struct LaunchWalletAuthenticationScreen: View {
    let database: WalletDatabase
    let settings: WalletSecuritySettings
    let onAuthenticated: () -> Void

    var body: some View {
        WalletSecurityAuthenticationView(
            database: database,
            settings: settings,
            purpose: .appUnlock,
            onAuthenticated: onAuthenticated
        )
    }
}

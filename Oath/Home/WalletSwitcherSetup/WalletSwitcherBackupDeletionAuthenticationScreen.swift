import SwiftUI

struct WalletSwitcherBackupDeletionAuthenticationScreen: View {
    let database: WalletDatabase
    let context: WalletAuthenticationPasscodeContext
    let onAuthenticated: () -> Void

    var body: some View {
        WalletSecurityAuthenticationView(
            database: database,
            settings: context.settings,
            purpose: .deleteICloudBackup,
            beginsWithPasscode: true,
            initialErrorKey: context.initialErrorKey
        ) {
            onAuthenticated()
        }
    }
}

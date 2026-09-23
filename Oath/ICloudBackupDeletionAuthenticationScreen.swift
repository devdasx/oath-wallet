import SwiftUI

enum ICloudBackupDeletionAuthorizationDecision: Equatable {
    case deleteWithoutAuthentication
    case authenticate
}

enum ICloudBackupDeletionAuthorizationPolicy {
    static func decision(
        settings: WalletSecuritySettings
    ) -> ICloudBackupDeletionAuthorizationDecision {
        settings.requiresAuthentication
            ? .authenticate
            : .deleteWithoutAuthentication
    }
}

struct ICloudBackupDeletionAuthenticationScreen: View {
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

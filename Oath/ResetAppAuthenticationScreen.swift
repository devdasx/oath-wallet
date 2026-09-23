import SwiftUI

struct ResetAppAuthenticationRoute: Identifiable, Hashable, Sendable {
    let id = UUID()
    let context: WalletAuthenticationPasscodeContext

    static func == (
        lhs: ResetAppAuthenticationRoute,
        rhs: ResetAppAuthenticationRoute
    ) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct ResetAppAuthenticationScreen: View {
    let database: WalletDatabase
    let context: WalletAuthenticationPasscodeContext
    let onAuthenticationGranted: () -> Void

    var body: some View {
        WalletSecurityAuthenticationView(
            database: database,
            settings: context.settings,
            purpose: .resetAppData,
            beginsWithPasscode: true,
            allowsBiometricFallback: false,
            initialErrorKey: context.initialErrorKey
        ) {
            onAuthenticationGranted()
        }
    }
}

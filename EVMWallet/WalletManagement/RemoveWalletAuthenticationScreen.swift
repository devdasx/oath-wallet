import SwiftUI

struct RemoveWalletAuthenticationRoute: Identifiable, Hashable, Sendable {
    let id = UUID()
    let context: WalletAuthenticationPasscodeContext

    static func == (
        lhs: RemoveWalletAuthenticationRoute,
        rhs: RemoveWalletAuthenticationRoute
    ) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct RemoveWalletAuthenticationScreen: View {
    let database: WalletDatabase
    let context: WalletAuthenticationPasscodeContext
    let onAuthenticationGranted: () -> Void

    var body: some View {
        WalletSecurityAuthenticationView(
            database: database,
            settings: context.settings,
            purpose: .removeWallet,
            beginsWithPasscode: true,
            allowsBiometricFallback: false,
            initialErrorKey: context.initialErrorKey
        ) {
            onAuthenticationGranted()
        }
    }
}

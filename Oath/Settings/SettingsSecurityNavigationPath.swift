import SwiftUI

/// Keeps Security authorization scoped to one visit when native back navigation
/// removes its route. Entry is an explicit Settings action, so `.security` is
/// published only after authentication has completed successfully.
@MainActor
enum SettingsSecurityNavigationPath {
    static func binding(
        to path: Binding<[WalletSettingsSearchRoute]>,
        securityDidExit: @escaping () -> Void = {}
    ) -> Binding<[WalletSettingsSearchRoute]> {
        Binding(
            get: { path.wrappedValue },
            set: { requestedPath, transaction in
                if path.wrappedValue.contains(.security),
                   !requestedPath.contains(.security) {
                    securityDidExit()
                }

                path.transaction(transaction).wrappedValue = requestedPath
            }
        )
    }
}

import SwiftUI

/// The Settings flow can start at its overview or at a Home option. Only routes
/// below that entry belong in the stack, so the entry has Close rather than Back.
struct SettingsSheetNavigationContainer<Root: View, Destination: View>: View {
    @Binding var path: [WalletSettingsSearchRoute]
    let securityDidExit: () -> Void
    let onClose: () -> Void
    @ViewBuilder let root: () -> Root
    @ViewBuilder let destination: (WalletSettingsSearchRoute) -> Destination

    var body: some View {
        NavigationStack(path: (SettingsSecurityNavigationPath.binding(
            to: $path, securityDidExit: securityDidExit
        ))) {
            root()
                .toolbar {
                    if path.isEmpty {
                        ToolbarItem(placement: .cancellationAction) {
                            WalletCloseButton(action: onClose)
                                .accessibilityIdentifier("settings-sheet-close")
                        }
                    }
                }
                .navigationDestination(for: WalletSettingsSearchRoute.self, destination: destination)
        }
    }
}

enum SettingsSheetNavigationPath {
    static func relative(
        _ routes: [WalletSettingsSearchRoute],
        to root: WalletSettingsSearchRoute
    ) -> [WalletSettingsSearchRoute] {
        root != .root && routes.first == root ? Array(routes.dropFirst()) : routes
    }
}

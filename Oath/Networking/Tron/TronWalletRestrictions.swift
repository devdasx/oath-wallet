import SwiftUI

private struct WalletMultisigRestrictedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var walletMultisigRestricted: Bool {
        get { self[WalletMultisigRestrictedKey.self] }
        set { self[WalletMultisigRestrictedKey.self] = newValue }
    }
}

private struct WalletTransferActionAvailability: ViewModifier {
    @Environment(\.walletMultisigRestricted) private var restricted

    func body(content: Content) -> some View {
        content.disabled(restricted)
    }
}

extension View {
    func walletTransferAction() -> some View {
        modifier(WalletTransferActionAvailability())
    }
}

extension AppRootView {
    var isWalletMultisigRestricted: Bool {
        confirmedTronChecks.contains {
            $0.showsWarning(for: walletPresentation.identity?.walletID)
        }
    }

    @MainActor
    func observeConfirmedTronChecks() async {
        do {
            for try await checks in database.confirmedTronChecks() {
                guard !Task.isCancelled else { return }
                confirmedTronChecks = checks
                if let presentation = walletActionPresentation,
                   checks.contains(where: { $0.showsWarning(for: presentation.context.identity.walletID) }) {
                    walletActionPresentation = nil
                }
            }
        } catch {
            // Keep already confirmed findings if observation is interrupted.
        }
    }
}

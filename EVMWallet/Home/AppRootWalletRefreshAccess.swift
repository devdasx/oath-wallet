import SwiftUI

extension AppRootView {
    @MainActor
    func permitsWalletRefresh(context: AppRootResolvedWalletContext) async -> Bool {
#if DEBUG
        if CommandLine.arguments.contains("--marketing-screenshot") {
            return false
        }
#endif
        return !Task.isCancelled && walletPresentation.accepts(context)
    }
}

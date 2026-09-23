import SwiftUI

private struct WalletHomeAssetPinAction: ViewModifier {
    let isPinned: Bool
    let action: () -> Void
    @State private var completion = WalletHomeSwipeCompletion()

    func body(content: Content) -> some View {
        content
            .background(WalletHomeSwipeCompletionAnchor(completion: completion))
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button(action: UniHaptic.action {
                    UniHaptic.play(.selection)
                    completion.performAfterClosing { action() }
                }) {
                    Text(LocalizedStringKey(isPinned
                        ? "wallet.home.assets.unpin.action"
                        : "wallet.home.assets.pin.action"))
                }
                .tint(WalletTheme.accent)
                .accessibilityIdentifier(isPinned ? "home.asset.unpin" : "home.asset.pin")
            }
    }
}

extension View {
    func walletHomeAssetPinAction(isPinned: Bool, action: @escaping () -> Void) -> some View {
        modifier(WalletHomeAssetPinAction(isPinned: isPinned, action: action))
    }
}

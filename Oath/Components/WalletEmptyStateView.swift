import SwiftUI

enum WalletEmptyStateSymbol {
    static let systemName = "circle.dashed"
}

struct WalletEmptyStateView: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey?

    init(
        _ title: LocalizedStringKey,
        message: LocalizedStringKey? = nil
    ) {
        self.title = title
        self.message = message
    }

    var body: some View {
        if let message {
            ContentUnavailableView(
                title,
                systemImage: WalletEmptyStateSymbol.systemName,
                description: Text(message)
            )
            .emptyStatePresentation()
        } else {
            ContentUnavailableView(
                title,
                systemImage: WalletEmptyStateSymbol.systemName
            )
            .emptyStatePresentation()
        }
    }
}

struct WalletSearchEmptyStateView: View {
    var body: some View {
        WalletEmptyStateView(
            "common.search.empty.title",
            message: "common.search.empty.message"
        )
    }
}

private extension View {
    func emptyStatePresentation() -> some View {
        symbolRenderingMode(.hierarchical)
            .accessibilityElement(children: .combine)
    }
}

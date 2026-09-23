import SwiftUI

enum AppReviewAnimationHeroMetrics {
    static let sideLength: CGFloat = 104
    static let symbolPointSize: CGFloat = 82
    static let sentimentSymbolName = "heart.square"
    static let thanksSymbolName = "checkmark.seal"
    static let effectOptions: SymbolEffectOptions = .nonRepeating
}

struct AppReviewAnimationHero: View {
    enum Kind {
        case sentiment
        case thanks

        var symbolName: String {
            switch self {
            case .sentiment:
                AppReviewAnimationHeroMetrics.sentimentSymbolName
            case .thanks:
                AppReviewAnimationHeroMetrics.thanksSymbolName
            }
        }

        var color: Color {
            switch self {
            case .sentiment:
                WalletTheme.accent
            case .thanks:
                WalletTheme.success
            }
        }
    }

    let kind: Kind

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion
    @State private var isSymbolVisible = false

    init(kind: Kind = .sentiment) {
        self.kind = kind
    }

    var body: some View {
        ZStack {
            if isSymbolVisible {
                Image(systemName: kind.symbolName)
                    .font(
                        .system(
                            size: AppReviewAnimationHeroMetrics
                                .symbolPointSize,
                            weight: WalletSFSymbol.weight
                        )
                    )
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(kind.color)
                    .walletDrawOnTransition(
                        options: AppReviewAnimationHeroMetrics.effectOptions
                    )
                    .symbolEffectsRemoved(reduceMotion)
            }
        }
        .frame(
            width: AppReviewAnimationHeroMetrics.sideLength,
            height: AppReviewAnimationHeroMetrics.sideLength
        )
        .task {
            guard !isSymbolVisible else { return }

            // Draw On reveals an inserted symbol. Commit the empty state first
            // so SwiftUI receives the insertion edge that starts the effect.
            await Task.yield()
            guard !Task.isCancelled else { return }

            withAnimation(reduceMotion ? nil : .smooth) {
                isSymbolVisible = true
            }
        }
        .accessibilityHidden(true)
    }
}

import SwiftUI

enum WalletCurrencyBalanceDisplayMode: Equatable, Sendable {
    case animatedValue
    case staticPrivacyPlaceholder

    init(isHidden: Bool) {
        self = isHidden
            ? .staticPrivacyPlaceholder
            : .animatedValue
    }
}

struct WalletPrivacyAwareCurrencyBalance: View {
    let usdValue: Decimal
    let currencyContext: WalletCurrencyContext
    let isHidden: Bool

    private var displayMode: WalletCurrencyBalanceDisplayMode {
        WalletCurrencyBalanceDisplayMode(isHidden: isHidden)
    }

    var body: some View {
        Group {
            switch displayMode {
            case .animatedValue:
                WalletAnimatedCurrencyBalance(
                    usdValue: usdValue,
                    currencyContext: currencyContext
                )
                .walletPrivacySensitive()

            case .staticPrivacyPlaceholder:
                WalletPrivacyReplacement(isHidden: true) {
                    Text(
                        verbatim: EnglishNumbers.currency(
                            usdValue,
                            using: currencyContext
                        )
                    )
                    .monospacedDigit()
                    .foregroundStyle(WalletTheme.secondaryLabel)
                }
            }
        }
        .transaction { transaction in
            guard displayMode == .staticPrivacyPlaceholder else {
                return
            }
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}

struct WalletHeroCurrencyBalance: View {
    let usdValue: Decimal
    let currencyContext: WalletCurrencyContext
    let isHidden: Bool

    @ScaledMetric private var fontSize: CGFloat

    private let minimumHeight: CGFloat

    init(
        usdValue: Decimal,
        currencyContext: WalletCurrencyContext,
        isHidden: Bool,
        fontSize: CGFloat = 48,
        minimumHeight: CGFloat = 58
    ) {
        self.usdValue = usdValue
        self.currencyContext = currencyContext
        self.isHidden = isHidden
        _fontSize = ScaledMetric(
            wrappedValue: fontSize,
            relativeTo: .largeTitle
        )
        self.minimumHeight = minimumHeight
    }

    var body: some View {
        WalletPrivacyAwareCurrencyBalance(
            usdValue: usdValue,
            currencyContext: currencyContext,
            isHidden: isHidden
        )
        .font(
            .system(
                size: fontSize,
                weight: .bold,
                design: .rounded
            )
        )
        .fontWidth(.expanded)
        .multilineTextAlignment(.center)
        .lineLimit(1)
        // Keep the complete amount inside its proposed width, even for large
        // converted balances or accessibility text sizes. Text owns the fit
        // and the existing numeric content transition animates its changes.
        .minimumScaleFactor(0.01)
        .frame(maxWidth: .infinity, minHeight: minimumHeight)
    }
}

struct WalletAnimatedCurrencyBalance: View {
    let usdValue: Decimal
    let currencyContext: WalletCurrencyContext

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let presentation = WalletCurrencyBalancePresentation(
            usdValue: usdValue,
            currencyContext: currencyContext
        )
        let text = presentation.text(
            colorPlan: WalletCurrencyBalanceColorPlan(isHidden: false)
        )

        if reduceMotion {
            text
                .monospacedDigit()
        } else {
            text
                .monospacedDigit()
                .contentTransition(
                    .numericText(value: presentation.animationValue)
                )
                .animation(
                    .smooth(duration: 0.3),
                    value: presentation.formatted
                )
        }
    }
}

enum WalletCurrencyBalanceColorRole: Equatable {
    case primary
    case gray

    var color: Color {
        switch self {
        case .primary:
            WalletTheme.primaryLabel
        case .gray:
            WalletTheme.secondaryLabel
        }
    }
}

struct WalletCurrencyBalanceColorPlan: Equatable {
    let leading: WalletCurrencyBalanceColorRole
    let fraction: WalletCurrencyBalanceColorRole
    let trailing: WalletCurrencyBalanceColorRole

    init(isHidden: Bool) {
        leading = isHidden ? .gray : .primary
        fraction = isHidden ? .gray : .primary
        trailing = isHidden ? .gray : .primary
    }
}

struct WalletCurrencyBalancePresentation: Equatable {
    let formatted: String
    let primaryLeading: String
    let secondaryFraction: String
    let primaryTrailing: String
    let animationValue: Double

    init(
        usdValue: Decimal,
        currencyContext: WalletCurrencyContext
    ) {
        let convertedValue = usdValue * currencyContext.ratePerUSD
        let formatted = EnglishNumbers.currency(
            usdValue,
            using: currencyContext
        )
        let parts = Self.splitFraction(in: formatted)
        let doubleValue = NSDecimalNumber(
            decimal: convertedValue
        ).doubleValue

        self.formatted = formatted
        primaryLeading = parts.leading
        secondaryFraction = parts.fraction
        primaryTrailing = parts.trailing
        animationValue = doubleValue.isFinite ? doubleValue : 0
    }

    init(formatted: String, animationValue: Double) {
        let parts = Self.splitFraction(in: formatted)

        self.formatted = formatted
        primaryLeading = parts.leading
        secondaryFraction = parts.fraction
        primaryTrailing = parts.trailing
        self.animationValue = animationValue
    }

    func text(
        segmentSeparator: String = "",
        colorPlan: WalletCurrencyBalanceColorPlan = .init(
            isHidden: false
        )
    ) -> Text {
        let leading = Text(verbatim: primaryLeading)
            .foregroundColor(colorPlan.leading.color)
        let fractionSeparator = Text(
            verbatim: secondaryFraction.isEmpty
                ? ""
                : segmentSeparator
        )
        let fraction = Text(verbatim: secondaryFraction)
            .foregroundColor(colorPlan.fraction.color)
        let trailingSeparator = Text(
            verbatim: primaryTrailing.isEmpty
                ? ""
                : segmentSeparator
        )
        let trailing = Text(verbatim: primaryTrailing)
            .foregroundColor(colorPlan.trailing.color)

        return Text(
            "\(leading)\(fractionSeparator)\(fraction)\(trailingSeparator)\(trailing)"
        )
    }

    private static func splitFraction(
        in formatted: String
    ) -> (leading: String, fraction: String, trailing: String) {
        guard let separatorIndex = formatted.lastIndex(of: ".") else {
            return (formatted, "", "")
        }

        let firstFractionIndex = formatted.index(after: separatorIndex)
        var fractionEndIndex = firstFractionIndex
        while
            fractionEndIndex < formatted.endIndex,
            isASCIIDigit(formatted[fractionEndIndex])
        {
            fractionEndIndex = formatted.index(after: fractionEndIndex)
        }

        guard fractionEndIndex > firstFractionIndex else {
            return (formatted, "", "")
        }

        return (
            String(formatted[..<separatorIndex]),
            String(formatted[separatorIndex..<fractionEndIndex]),
            String(formatted[fractionEndIndex...])
        )
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        guard
            character.unicodeScalars.count == 1,
            let scalar = character.unicodeScalars.first
        else {
            return false
        }
        return scalar.value >= 48 && scalar.value <= 57
    }
}

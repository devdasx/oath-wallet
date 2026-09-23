import SwiftUI

// This isolated test app uses fixed synthetic amounts and owns no wallet data.
struct WalletCurrencyContext {
    let code: String
    let ratePerUSD: Decimal
}

enum EnglishNumbers {
    static func currency(_ amount: Decimal, using context: WalletCurrencyContext) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return context.code + " " + (formatter.string(from: NSDecimalNumber(decimal: amount * context.ratePerUSD)) ?? "0.00")
    }
}

enum WalletTheme {
    static let onDarkColorLabel = Color.white
    static let onLightColorLabel = Color.black
    static let primaryLabel = Color.primary
    static let secondaryLabel = Color.secondary
}

struct WalletPrivacyReplacement<Content: View>: View {
    let isHidden: Bool
    @ViewBuilder let content: () -> Content

    var body: some View { content().redacted(reason: isHidden ? .placeholder : []) }
}

extension View {
    func walletPrivacySensitive() -> some View { privacySensitive() }
}

import SwiftUI

@main
struct HomeBalanceCardFixtureApp: App {
    var body: some Scene {
        WindowGroup { BalanceCardFixtureScreen() }
    }
}

private struct BalanceCardFixtureScreen: View {
    @State private var amount: Decimal = 1
    @State private var isHidden = false
    @State private var privacyCount = 0
    @State private var receiveCount = 0
    @State private var cardSize: CGSize = .zero

    private let options = ProcessInfo.processInfo.environment
    private var locale: Locale { Locale(identifier: options["APERTURE_FIXTURE_LANGUAGE"] ?? "en") }
    private var maximumWidth: CGFloat { options["APERTURE_FIXTURE_NARROW"] == "1" ? 320 : .infinity }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                WalletHomeBalanceCard(
                    usdValue: amount,
                    currencyContext: WalletCurrencyContext(code: "IRR", ratePerUSD: 1),
                    isHidden: isHidden,
                    isAnimationEnabled: false,
                    onTogglePrivacy: {
                        privacyCount += 1
                        isHidden.toggle()
                    },
                    onReceive: { receiveCount += 1 }
                )
                .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                .padding(.horizontal, 20)
                .frame(maxWidth: maximumWidth)

                HStack {
                    Button { amount = 1 } label: { Text(verbatim: "1") }
                        .accessibilityIdentifier("fixture-small-amount")
                    Button { amount = Decimal(string: "211656098495.01")! } label: {
                        Text(verbatim: "211656098495.01")
                    }
                    .accessibilityIdentifier("fixture-large-amount")
                }
                .buttonStyle(.bordered)
                Text(verbatim: String(privacyCount)).accessibilityIdentifier("fixture-privacy-count")
                Text(verbatim: String(receiveCount)).accessibilityIdentifier("fixture-receive-count")
                Text(verbatim: "\(cardSize.width);\(cardSize.height)")
                    .accessibilityIdentifier("fixture-card-size")
            }
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .environment(\.locale, locale)
        .environment(\.layoutDirection,
                     locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight)
        .environment(\.dynamicTypeSize, options["APERTURE_FIXTURE_LARGE_TEXT"] == "1" ? .accessibility3 : .large)
        .preferredColorScheme(options["APERTURE_FIXTURE_DARK"] == "1" ? .dark : .light)
    }
}

import SwiftUI

struct WalletHomeBalanceCard: View {
    let usdValue: Decimal
    let currencyContext: WalletCurrencyContext
    let isHidden: Bool
    let onTogglePrivacy: () -> Void
    let onReceive: () -> Void

    var body: some View {
        WalletHomeBalanceCardLayout {
            VStack(alignment: .leading, spacing: 2) {
                Text("wallet.home.balance.label")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(WalletTheme.balanceCardSecondaryInk)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                receiveChip
                Spacer(minLength: 0)
                balanceButton
            }
            .padding(WalletHomeBalanceCardMetrics.contentInset)
        }
        .background {
            WalletTheme.balanceCardSurface
                .overlay {
                    WalletHomeBalanceCardGrid()
                        .stroke(
                            WalletTheme.balanceCardGrid,
                            lineWidth: WalletHomeBalanceCardMetrics.gridLineWidth
                        )
                }
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .clipShape(.rect(cornerRadius: WalletHomeBalanceCardMetrics.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: WalletHomeBalanceCardMetrics.cornerRadius)
                .strokeBorder(WalletTheme.balanceCardBorder, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wallet-home-balance-card")
    }

    private var receiveChip: some View {
        WalletHomeBalanceChipRowLayout {
            GeometryReader { geometry in
                let cardWidth = geometry.size.width + WalletHomeBalanceCardMetrics.contentInset * 2
                let size = WalletHomeBalanceCardMetrics.chipSize(cardWidth: cardWidth)
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Button(action: UniHaptic.action(nil, perform: onReceive)) {
                        Image(systemName: "qrcode")
                            .font(.system(size: size.height * 0.57, weight: .regular))
                            .foregroundStyle(WalletTheme.balanceCardInk)
                            .frame(width: size.width, height: size.height)
                            .background(WalletTheme.balanceCardChipSurface,
                                        in: .rect(cornerRadius: size.height * 0.22))
                            .overlay {
                                RoundedRectangle(cornerRadius: size.height * 0.22)
                                    .strokeBorder(WalletTheme.balanceCardChipBorder, lineWidth: 1)
                                    .allowsHitTesting(false)
                            }
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("wallet.home.action.receive")
                    .accessibilityIdentifier("wallet-home-balance-card-qr")
                    .walletTransferAction()
                }
                .padding(.trailing, WalletHomeBalanceCardMetrics.chipTrailingInset)
            }
        }
    }

    private var balanceButton: some View {
        Button(action: UniHaptic.action(onTogglePrivacy)) {
            WalletHomeCardBalanceValue(
                usdValue: usdValue, currencyContext: currencyContext, isHidden: isHidden
            )
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isHidden
            ? Text("wallet.home.balance.show.accessibility")
            : Text("wallet.home.balance.hide.accessibility"))
        .accessibilityValue(isHidden
            ? Text("wallet.home.balance.hidden")
            : Text(verbatim: EnglishNumbers.currency(usdValue, using: currencyContext)))
        .accessibilityIdentifier("wallet-home-balance-card-value")
    }

}

private struct WalletHomeCardBalanceValue: View {
    let usdValue: Decimal
    let currencyContext: WalletCurrencyContext
    let isHidden: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var fontSize: CGFloat = 44

    var body: some View {
        let presentation = WalletCurrencyBalancePresentation(usdValue: usdValue, currencyContext: currencyContext)
        Text(verbatim: presentation.formatted)
            .foregroundStyle(WalletTheme.balanceCardInk)
            .font(.system(size: fontSize, weight: .bold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.01)
            .multilineTextAlignment(.leading)
            .contentTransition(reduceMotion || isHidden ? .identity : .numericText(value: presentation.animationValue))
            .animation(reduceMotion || isHidden ? nil : .smooth(duration: 0.3), value: presentation.formatted)
            .redacted(reason: isHidden ? .placeholder : [])
            .walletPrivacySensitive()
            .accessibilityHidden(isHidden)
            .transaction { if isHidden { $0.animation = nil; $0.disablesAnimations = true } }
            // The card's height stays steady when a long amount scales down.
            .frame(minHeight: fontSize * 1.25, alignment: .leading)
    }
}

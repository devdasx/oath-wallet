import SwiftUI

extension EnglishNumbers {
    static func walletActivityTimestamp(
        _ date: Date,
        relativeTo now: Date = Date()
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let isToday = calendar.isDate(date, inSameDayAs: now)
        let isYesterday = calendar
            .date(byAdding: .day, value: -1, to: now)
            .map { calendar.isDate(date, inSameDayAs: $0) }
            ?? false

        guard isToday || isYesterday else {
            return walletActivityDay(date, relativeTo: now)
        }
        return walletTimestamp(date, relativeTo: now)
    }
}

struct WalletTransactionRow: View {
    let transaction: WalletTransaction
    let isBalanceHidden: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.walletCurrencyContext) private var currencyContext

    var body: some View {
        let assetAmount = EnglishNumbers.localized(
            "wallet.format.asset_amount",
            transaction.displayAssetAmountText,
            transaction.assetSymbol
        )
        let fiatAmount = transaction.fiatValue.map {
            EnglishNumbers.currency($0, using: currencyContext)
        }

        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    identity
                    values(
                        assetAmount: assetAmount,
                        fiatAmount: fiatAmount
                    )
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    identity
                    Spacer(minLength: 12)
                    values(
                        assetAmount: assetAmount,
                        fiatAmount: fiatAmount
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var identity: some View {
        HStack(alignment: .top, spacing: 14) {
            transactionLogo

            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.activityTitle)
                    .font(WalletTypography.listRowTitle)
                    .foregroundStyle(WalletTheme.primaryLabel)
                    .lineLimit(2)

                if !transaction.activitySubtitle.isEmpty {
                    Text(transaction.activitySubtitle)
                        .font(.caption)
                        .foregroundStyle(WalletTheme.secondaryLabel)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .allowsTightening(true)
                }
            }
        }
    }

    private func values(
        assetAmount: String,
        fiatAmount: String?
    ) -> some View {
        VStack(
            alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing,
            spacing: 5
        ) {
            WalletPrivacyReplacement(
                isHidden: isBalanceHidden,
                alignment: dynamicTypeSize.isAccessibilitySize
                    ? .leading
                    : .trailing
            ) {
                VStack(
                    alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing,
                    spacing: 5
                ) {
                    Text(assetAmount)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(transaction.activityAmountColor)

                    if let fiatAmount {
                        Text(verbatim: fiatAmount)
                            .font(.caption)
                            .foregroundStyle(WalletTheme.secondaryLabel)
                    }
                }
            }
        }
    }

    private var transactionLogo: some View {
        ZStack(alignment: .bottomTrailing) {
            AssetLogoView(source: transaction.assetLogoSource)

            WalletLogoStatusBadge(
                color: transaction.activityBadgeColor,
                systemSymbol: transaction.activityBadgeSymbol,
                size: 22
            )
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }

}

/// Shared by history, asset activity, and the pending-activity list.
extension WalletTransaction {
    var activityAmountColor: Color {
        switch status {
        case .pending, .confirmed:
            WalletTheme.primaryLabel
        case .canceled, .replaced, .failed, .notFound:
            WalletTheme.secondaryLabel
        }
    }

    var activityBadgeSymbol: String {
        switch status {
        case .pending:
            "clock.fill"
        case .canceled:
            "xmark"
        case .failed, .notFound, .replaced:
            "exclamationmark"
        case .confirmed:
            kind.systemSymbol
        }
    }

    var activityBadgeColor: Color {
        switch status {
        case .pending, .notFound, .replaced:
            WalletTheme.warning
        case .canceled:
            WalletTheme.secondaryLabel
        case .failed:
            WalletTheme.danger
        case .confirmed:
            switch kind {
            case .received:
                WalletTheme.success
            case .sent:
                WalletTheme.danger
            case .selfTransfer:
                WalletTheme.accent
            case .swapped:
                WalletTheme.secondaryLabel
            }
        }
    }
}

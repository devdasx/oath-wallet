import SwiftUI
import OathDatabase

/// The session owns today's comparison independently of view visibility. Home
/// visibility records a visit; it must never invalidate the displayed baseline.
struct OathBalanceChangePill: View {
    let session: OathWalletSession
    let visible: Bool
    @Environment(\.oathLocalizer) private var strings
    @State private var day = BalanceDaySummary.interval(containing: Date())

    private struct Context: Hashable {
        let walletID: String
        let currency: String
        let day: DateInterval
    }
    private var context: Context? {
        guard let portfolio = session.portfolio else { return nil }
        return Context(walletID: portfolio.wallet.id, currency: portfolio.currency, day: day)
    }
    private var visitContext: Context? { visible ? context : nil }
    private var change: BalanceDayChange? {
        session.balanceChange(on: day)
    }
    private var color: Color {
        guard !session.balancesHidden, let change else { return .white.opacity(0.85) }
        return change.amount > 0 ? Color(red: 0.61, green: 0.96, blue: 0.75)
            : change.amount < 0 ? Color(red: 1, green: 0.67, blue: 0.69) : .white.opacity(0.85)
    }
    private var amount: String? {
        guard let change, let context else { return nil }
        return change.amount.formatted(.currency(code: context.currency)
            .sign(strategy: .always(showZero: false)).locale(.autoupdatingCurrent))
    }
    private var percentage: String? {
        guard let value = change?.percentage else { return nil }
        return (value / 100).formatted(.percent.precision(.fractionLength(2)).locale(.autoupdatingCurrent))
    }
    private var accessibilityValue: String {
        if session.balancesHidden { return strings.text(.balanceHidden) }
        guard change != nil else { return strings.text(.balanceChangeUnavailable) }
        return [amount, percentage, strings.text(.balanceChangeToday)].compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        Group {
            // A failed first-ever local read has no truthful comparison to
            // display. Do not manufacture a dash, zero, or another day's gain.
            // Normal startup preloads the summary before revealing Home.
            if change != nil || session.balancesHidden {
                content
            }
        }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(strings.text(.balanceChangeTitle))
            .accessibilityValue(accessibilityValue)
            .accessibilityIdentifier("home.balanceChange")
            .onChange(of: visible, initial: true) { _, active in
                if active { updateDay() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in updateDay() }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in updateDay() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in updateDay() }
            .task(id: context) {
                guard context != nil else { return }
                await session.refreshBalanceDay()
            }
            .task(id: visitContext) {
                guard visitContext != nil else { return }
                await session.recordBalanceSnapshot(.homeVisit)
                await session.refreshBalanceDay()
            }
    }

    @ViewBuilder private var content: some View {
        if #available(iOS 26.0, *) {
            label.glassEffect(.clear, in: Capsule())
        } else {
            label.background(.ultraThinMaterial, in: Capsule())
        }
    }
    private var label: some View {
        HStack(spacing: 6) {
            if session.balancesHidden {
                Text(verbatim: "••••")
            } else {
                if let change, change.amount != 0 {
                    Image(systemName: change.amount > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                        .font(.caption2).foregroundStyle(color)
                }
                if let amount { Text(amount).fontWeight(.semibold).foregroundStyle(color) }
                if let percentage { Text(verbatim: "(\(percentage))").foregroundStyle(.white.opacity(0.85)) }
                Text(strings.text(.balanceChangeToday)).foregroundStyle(.white.opacity(0.85))
            }
        }
        .oathFont(.subheadline, weight: .medium)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.65)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
    private func updateDay() {
        let current = BalanceDaySummary.interval(containing: Date())
        if day != current { day = current }
    }
}

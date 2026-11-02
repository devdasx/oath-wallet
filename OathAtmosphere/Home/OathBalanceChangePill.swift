import SwiftUI
import OathDatabase
import OathDiagnostics

/// Today's preloaded comparison stays session-owned. Longer periods observe
/// the same local history without replacing or resetting that daily baseline.
struct OathBalanceChangePill: View {
    let session: OathWalletSession
    let visible: Bool
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var day = BalanceDaySummary.interval(containing: Date())
    @State private var period: BalanceHistoryPeriod = .today
    @State private var showingPeriods = false
    @State private var selectionRevision = 0
    @State private var periodSummary: BalanceDaySummary?

    private struct Context: Hashable {
        let walletID: String
        let currency: String
        let day: DateInterval
    }
    private struct PeriodContext: Hashable {
        let context: Context
        let period: BalanceHistoryPeriod
        let revision: Int
    }
    private var context: Context? {
        guard let portfolio = session.portfolio else { return nil }
        return Context(walletID: portfolio.wallet.id, currency: portfolio.currency, day: day)
    }
    private var visitContext: Context? { visible ? context : nil }
    private var periodContext: PeriodContext? {
        guard session.isUnlocked, !session.changingWallet, !session.resetting, period != .today, let context else { return nil }
        return PeriodContext(context: context, period: period, revision: selectionRevision)
    }
    private var matchingSummary: BalanceDaySummary? {
        guard let context, let summary = periodSummary,
              summary.walletID == context.walletID,
              summary.interval == period.interval(containing: day.start) else { return nil }
        return summary
    }
    private var snapshotChange: BalanceDayChange? {
        // Use the live portfolio immediately; history writes are coalesced.
        guard let portfolio = session.portfolio else { return nil }
        if period == .today {
            guard let context, let summary = session.balanceDaySummary,
                  summary.walletID == context.walletID,
                  summary.interval == day else { return nil }
            return summary.change(current: portfolio.totalFiat, currency: portfolio.currency, exchangeRate: portfolio.displayExchangeRate)
        }
        return matchingSummary?.change(current: portfolio.totalFiat, currency: portfolio.currency, exchangeRate: portfolio.displayExchangeRate)
    }
    private var change: BalanceDayChange? {
        snapshotChange
    }
    private var displayCurrency: String {
        context?.currency ?? Locale.autoupdatingCurrent.currency?.identifier ?? "USD"
    }
    private var hasNonzeroChange: Bool {
        (change?.amount ?? .zero) != .zero
    }
    private var color: Color {
        guard !session.balancesHidden, hasNonzeroChange, let change else { return .white.opacity(0.85) }
        return change.amount > 0 ? Color(red: 0.61, green: 0.96, blue: 0.75)
            : change.amount < 0 ? Color(red: 1, green: 0.67, blue: 0.69) : .white.opacity(0.85)
    }
    private var amount: String {
        // Sub-cent changes use the shared nonzero bound; only exact zero is zero.
        // Missing comparisons display zero without creating a history baseline.
        let value = change?.amount ?? .zero
        return OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: displayCurrency)
            .money(value, signed: true)
    }
    private var percentage: String? {
        guard let value = change == nil ? 0 : change?.percentage else { return nil }
        return ((hasNonzeroChange ? value : 0) / 100).formatted(.percent.precision(.fractionLength(2)).locale(strings.language.locale))
    }
    private var accessibilityValue: String {
        if session.balancesHidden { return strings.text(.balanceHidden) }
        return [amount, percentage, strings.text(period.titleKey)]
            .compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        OathButton { showingPeriods = true } label: { content }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(strings.text(.balanceChangePeriodTitle))
            .accessibilityValue(accessibilityValue)
            .accessibilityIdentifier("home.balanceChange")
            .sheet(isPresented: $showingPeriods) {
                OathBalancePeriodPicker(selected: period) { selected in
                    period = selected
                    selectionRevision += 1
                    showingPeriods = false
                }
            }
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
            .task(id: periodContext) {
                guard let scope = periodContext else { return }
                await OathDiagnostics.$operationID.withValue(UUID()) {
                    do {
                        let observations = try await session.observeBalancePeriod(scope.period, at: scope.context.day.start)
                        for try await summary in observations {
                            guard !Task.isCancelled, periodContext == scope else { return }
                            periodSummary = summary
                        }
                    } catch is CancellationError { } // Expected selection, lock, wallet change or teardown.
                    catch {
                        OathDiagnostics.record(error, component: "balance_history", operation: "observe_period")
                    }
                }
            }
    }

    private var content: some View {
        label.background {
            ZStack {
                if reduceTransparency {
                    Color(white: 0.18)
                } else {
                    OathBalanceChangeBackdrop()
                    LinearGradient(colors: [.white.opacity(0.09), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .clipShape(Capsule())
            .overlay {
                Capsule().strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.04), .white.opacity(0.12)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
    private var label: some View {
        HStack(spacing: 6) {
            if let change, hasNonzeroChange {
                Image(systemName: change.amount > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                    .font(.caption2).foregroundStyle(color)
            }
            Text(amount).fontWeight(.semibold).foregroundStyle(color)
            if let percentage { Text(verbatim: "(\(percentage))").foregroundStyle(.white.opacity(0.85)) }
            Text(strings.text(period.titleKey)).foregroundStyle(.white.opacity(0.85))
        }
        .oathFont(.subheadline, weight: .medium)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.65)
        .oathBalanceConcealed(session.balancesHidden)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Capsule())
    }
    private func updateDay() {
        let current = BalanceDaySummary.interval(containing: Date())
        if day != current { day = current }
    }
}

/// A live native backdrop blur lets the moving artwork color the capsule.
/// Keep the effect fully opaque as a view: fading its alpha also fades the blur.
private struct OathBalanceChangeBackdrop: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}

private struct OathBalancePeriodPicker: View {
    let selected: BalanceHistoryPeriod
    let onChoose: (BalanceHistoryPeriod) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        OathContentSizedSheet(contentID: "balance.periods", navigation: .init(
            strings: strings, title: .balanceChangePeriodTitle, backIdentifier: "balance.periods.back",
            onBack: nil, onClose: { dismiss() }, preservesNativeButtonBackground: true
        ), opaqueBackground: true) {
            VStack(spacing: 0) {
                ForEach(BalanceHistoryPeriod.allCases, id: \.self) { period in
                    OathButton(feedback: .selection) { onChoose(period) } label: {
                        OathSettingsRow(title: strings.text(period.titleKey), accessory: .selection(period == selected))
                    }
                    .buttonStyle(OathSettingsRowButtonStyle())
                    .accessibilityAddTraits(period == selected ? .isSelected : [])
                    .accessibilityIdentifier("balance.period.\(period.rawValue)")
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
        }
        .presentationDragIndicator(.visible)
    }
}

private extension BalanceHistoryPeriod {
    var titleKey: OathStringKey {
        switch self {
        case .today: .historyToday
        case .week: .balanceChangeWeek
        case .month: .balanceChangeMonth
        case .sixMonths: .balanceChangeSixMonths
        case .year: .balanceChangeYear
        case .all: .balanceChangeAll
        }
    }
}

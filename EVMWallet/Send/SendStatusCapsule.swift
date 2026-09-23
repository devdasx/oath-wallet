import SwiftUI

struct SendStatusCapsule: View {
    let operation: SendOperation
    let onOpen: () -> Void
    let onDismiss: @MainActor () -> Void
    var onAutomaticDismiss: (@MainActor () -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var drag = CGSize.zero
    @State private var isDismissing = false

    private let shape = RoundedRectangle(cornerRadius: 34, style: .continuous)

    var body: some View {
        HStack(spacing: 4) {
            Button(action: UniHaptic.action(nil, perform: openDetails)) {
                HStack(spacing: 12) {
                    SendStatusAssetBadge(
                        asset: operation.draft.asset,
                        status: operation.capsuleStatus
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        SendActivityTitle(operation: operation)
                            .font(.headline)
                        Text(verbatim: operation.activityAssetSubtitle)
                            .font(.caption)
                            .foregroundStyle(WalletTheme.secondaryLabel)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(shape)
            }
            .accessibilityHint(Text("send.broadcast.navigation_title"))
            .accessibilityAction(.escape, dismiss)
            .accessibilityAction(named: Text("common.close"), dismiss)
            .accessibilityIdentifier("sendStatusCapsule")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .buttonStyle(.plain)
        .foregroundStyle(WalletTheme.primaryLabel)
        .walletRegularGlassEffect(interactive: true, in: shape)
        .offset(y: reduceMotion ? 0 : drag.height)
        .animation(reduceMotion || drag != .zero ? nil : .snappy(duration: 0.22), value: drag)
        .highPriorityGesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .global)
                .updating($drag) { value, state, _ in
                    guard !isDismissing,
                          value.translation.height < 0,
                          abs(value.translation.height) > abs(value.translation.width) else { return }
                    state = CGSize(width: 0, height: value.translation.height)
                }
                .onEnded { value in
                    if Self.shouldDismiss(translation: value.translation) { dismiss() }
                }
        )
        .onKeyPress(.escape) { dismiss(); return .handled }
        .disabled(isDismissing || operation.isAcknowledged)
        .modifier(SendActivityAutomaticDismissal(operation: operation, isEnabled: !isDismissing,
                                                dismissConfirming: true,
                                                onDismiss: onAutomaticDismiss ?? onDismiss))
    }

    /// Use actual upward travel; sideways/downward drags and a tap never dismiss.
    nonisolated static func shouldDismiss(translation: CGSize) -> Bool {
        translation.width.isFinite && translation.height.isFinite
            && translation.height <= -36
            && -translation.height > abs(translation.width)
    }

    private func openDetails() {
        guard !isDismissing, !operation.isAcknowledged else { return }
        onOpen()
    }

    private func dismiss() {
        guard !isDismissing, !operation.isAcknowledged else { return }
        operation.capsuleDismissal.cancel()
        isDismissing = true
        onDismiss()
    }
}

/// Shared by the single banner and its expanded activity list.
struct SendActivityTitle: View {
    let operation: SendOperation
    @Environment(\.walletCurrencyContext) private var currencyContext
    @Environment(\.locale) private var locale

    var body: some View {
        Group {
            if operation.capsuleStatus == .sending,
               let amount = SendAmountPresentation.activityAmount(
                   amount: operation.draft.amount, asset: operation.draft.asset,
                   currency: currencyContext,
                   nativeUnitUSDPrice: operation.nativeUnitUSDPrice,
                   cachedAssetUnitUSDPrice: operation.activityAssetUnitUSDPrice
               ) {
                Text(verbatim: String(
                    localized: "send.activity.sending_amount",
                    defaultValue: "Sending \(amount)…",
                    bundle: WalletAppLanguage.localizedBundle(for: locale.identifier),
                    locale: locale
                ))
            } else {
                Text(LocalizedStringKey(operation.capsuleStatus.titleKey))
            }
        }
        .task(id: operation.id) { await operation.loadActivityPriceIfNeeded() }
    }
}

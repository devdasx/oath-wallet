import SwiftUI

struct PushNotificationTransactionDetailScreen: View {
    @State private var model: NotificationTransactionDetailModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    init(notification: DBNotificationRecord, database: WalletDatabase) {
        _model = State(initialValue: NotificationTransactionDetailModel(notification: notification, database: database))
    }

    var body: some View {
        Group {
            if let context = model.context {
                WalletTransactionDetailsView(
                    transaction: context.transaction,
                    isBalanceHidden: false,
                    database: model.database,
                    allowsRepeat: false
                )
            } else {
                NotificationTransactionSkeleton()
            }
        }
        .background(WalletTheme.groupedBackground)
        .navigationTitle("wallet.transaction.details.title")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                WalletCloseButton { dismiss() }
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.run()
        }
    }
}

/// Mirrors the hero and native sections of WalletTransactionDetailsView without
/// presenting notification text as verified transaction data.
struct NotificationTransactionSkeleton: View {
    var body: some View {
        List {
            Group {
                Section {
                    VStack(spacing: 12) {
                        placeholder(width: 64, height: 64, radius: 32)
                        placeholder(width: 130, height: 24)
                        VStack(spacing: 4) {
                            placeholder(width: 230, height: 34)
                            placeholder(width: 85, height: 20)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 20, leading: 16, bottom: 24, trailing: 16))
                    .listRowSeparator(.hidden)
                }
                Section("wallet.transaction.details.overview.section") {
                    row("wallet.transaction.details.status")
                    row("wallet.transaction.details.date")
                    row("wallet.transaction.details.network")
                    row("wallet.transaction.details.from")
                    row("wallet.transaction.details.to")
                }
                Section("wallet.transaction.details.transfer.section") {
                    row("wallet.transaction.details.amount")
                    row("wallet.transaction.details.network_fee")
                }
                Section("wallet.transaction.details.notes.section") {
                    placeholder(width: 210, height: 22)
                        .frame(minHeight: 28)
                }
                Section {
                    row("wallet.transaction.details.hash")
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(WalletTheme.groupedBackground)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("notifications.transaction.loading"))
        .allowsHitTesting(false)
    }

    private func row(_ key: LocalizedStringKey) -> some View {
        LabeledContent {
            placeholder(width: 110, height: 18)
        } label: {
            Text(key).foregroundStyle(WalletTheme.primaryLabel)
        }
    }

    private func placeholder(width: CGFloat, height: CGFloat, radius: CGFloat = 6) -> some View {
        NotificationTransactionShimmer()
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .accessibilityHidden(true)
    }
}

private struct NotificationTransactionShimmer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var animates = false

    var body: some View {
        Rectangle()
            .fill(WalletTheme.secondaryLabel.opacity(0.13))
            .overlay {
                if !reduceMotion && scenePhase == .active {
                    GeometryReader { geometry in
                        LinearGradient(
                            colors: [.clear, WalletTheme.secondaryLabel.opacity(0.16), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .offset(x: animates ? geometry.size.width : -geometry.size.width)
                        .animation(.linear(duration: 1.4).repeatForever(autoreverses: false), value: animates)
                        .onAppear { animates = true }
                        .onDisappear { animates = false }
                    }
                }
            }
            .clipped()
    }
}

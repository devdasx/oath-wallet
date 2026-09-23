import SwiftUI

enum WalletSuccessKind: String, CaseIterable {
    case created, imported, restored

    var titleKey: LocalizedStringKey {
        switch self {
        case .created: "success.created.title"
        case .imported: "success.imported.title"
        case .restored: "success.restored.title"
        }
    }
}

struct WalletSuccessBackupContext {
    let database: WalletDatabase
    let walletID: String
}

/// Presentation only: preparation, persistence and completion stay in each flow.
struct WalletSuccessPresentation<Actions: View>: View {
    var kind: WalletSuccessKind = .created
    let isPreparing: Bool
    var backupContext: WalletSuccessBackupContext? = nil
    var allowsManualBackup = true
    @ViewBuilder let actions: () -> Actions
    @State private var isBackingUp = false

    var body: some View {
        WalletSuccessHero(
            kind: kind,
            backupContext: backupContext,
            allowsManualBackup: allowsManualBackup,
            onBackupBusyChange: { isBackingUp = $0 }
        )
            .background(WalletTheme.groupedBackground.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actions()
                    .disabled(isBackingUp)
                    .padding(.vertical, 12)
            }
            .interactiveDismissDisabled(isBackingUp)
    }
}

struct WalletSuccessHero: View {
    var kind: WalletSuccessKind = .created
    var backupContext: WalletSuccessBackupContext? = nil
    var allowsManualBackup = true
    var onBackupBusyChange: (Bool) -> Void = { _ in }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 34
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 17
    @ScaledMetric(relativeTo: .subheadline) private var detailSize: CGFloat = 15

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 570 || proxy.size.width < 360
            // Never swap the confirmation for a different layout after saving.
            // The applicable backup rows exist even while the wallet ID is pending.
            SettingsBackupMethodSelectionScreen(
                backupContext: backupContext,
                allowsManualBackup: allowsManualBackup,
                onBusyChange: onBackupBusyChange
            ) {
                VStack(spacing: compact ? 20 : 28) {
                    status(size: compact ? 40 : 64)
                    message(compact: compact)
                    guidance(compact: compact)
                }
                .padding(.top, compact ? 16 : 32)
                .padding(.bottom, compact ? 10 : 18)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func status(size: CGFloat) -> some View {
        Image(systemName: "checkmark.circle")
            .font(.system(size: size, weight: .light))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(WalletTheme.primaryLabel)
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityHidden(true)
            .frame(height: size)
            .frame(maxWidth: .infinity)
    }

    private func message(compact: Bool) -> some View {
        VStack(spacing: 12) {
            Text(kind.titleKey)
                .font(.system(size: titleSize * (compact ? 0.82 : 1), weight: .bold))
                .foregroundStyle(WalletTheme.primaryLabel)
                .lineSpacing(locale.language.languageCode?.identifier == "my" ? 12 : 3)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .minimumScaleFactor(0.75)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("walletSuccessTitle")

            Text("success.ready.message")
                .font(.system(size: bodySize * (compact ? 0.88 : 1)))
                .foregroundStyle(WalletTheme.secondaryLabel)
                .lineSpacing(3)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                .minimumScaleFactor(0.85)
                .accessibilityIdentifier("walletSuccessMessage")
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private func guidance(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 18 : 28) {
            detail(
                symbol: kind == .created ? "arrow.down.left.circle" : "arrow.triangle.2.circlepath",
                title: kind == .created ? "wallet.home.action.receive" : "success.sync.title",
                message: kind == .created ? "success.receive.message" : "success.sync.message",
                compact: compact
            )
            detail(symbol: "key.horizontal", title: "success.backup.title",
                   message: "success.backup.message", compact: compact)
        }
    }

    private func detail(
        symbol: String, title: LocalizedStringKey,
        message: LocalizedStringKey, compact: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 22 : 26, weight: .regular))
                .foregroundStyle(WalletTheme.secondaryLabel)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: detailSize * (compact ? 0.9 : 1), weight: .semibold))
                    .foregroundStyle(WalletTheme.primaryLabel)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                Text(message)
                    .font(.system(size: detailSize * (compact ? 0.87 : 1)))
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .lineSpacing(2)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
